import Foundation
import Darwin

/// Forwards guest API requests to api.anthropic.com with the real credential injected.
public final class Proxy {
    private let credentials: Credentials
    private let session: URLSession

    public init(credentials: Credentials) {
        self.credentials = credentials
        let cfg = URLSessionConfiguration.ephemeral
        // Not timeoutIntervalForResource, which would cap long streaming generations.
        cfg.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: cfg)
    }

    /// One request per connection.
    public func handle(_ fd: Int32) {
        defer { close(fd) }
        FDIO.setReadTimeout(fd, seconds: 10)
        Self.setWriteTimeout(fd, seconds: 30)
        guard let request = Self.readRequest(fd) else { return }
        guard let upstream = buildUpstreamRequest(request) else {
            _ = FDIO.writeAll(fd, Self.badGateway)
            return
        }
        let connection = ProxyConnection(fd: fd)
        let task = session.dataTask(with: upstream)
        task.delegate = connection
        task.resume()
        connection.wait()
    }

    // MARK: - Allowlist

    /// Matched exactly; /api/hello is the CLI's startup probe.
    static let allowedPaths: Set<String> = ["/v1/messages", "/v1/messages/count_tokens", "/api/hello"]
    static let upstreamHost = "api.anthropic.com"

    func buildUpstreamRequest(_ request: HTTPRequest) -> URLRequest? {
        let pathOnly = String(request.path.prefix { $0 != "?" })
        guard Self.allowedPaths.contains(pathOnly) else {
            Terminal.notice("proxy refused \(Self.printable(request.method)) \(Self.printable(request.path))")
            return nil
        }
        guard let injection = credentials.resolveAnthropic(),
              let url = Self.pinnedURL(host: Self.upstreamHost, guestPath: request.path)
        else { return nil }

        var headers = Self.stripCredentialHeaders(request.headers)
        // URLSession owns these; forwarding the guest's copies corrupts framing and routing.
        for managed in ["host", "content-length", "connection", "accept-encoding"] {
            headers[managed] = nil
        }
        switch injection {
        case .apiKey(let key):
            headers["x-api-key"] = key
        case .oauthBearer(let token):
            headers["authorization"] = "Bearer \(token)"
            Self.mergeAnthropicBeta(into: &headers, flag: Credentials.oauthBetaFlag)
        }

        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        for (key, value) in headers { upstream.setValue(value, forHTTPHeaderField: key) }
        if !request.body.isEmpty { upstream.httpBody = request.body }
        return upstream
    }

    static let credentialHeaders: Set<String> = ["authorization", "x-api-key"]

    static func stripCredentialHeaders(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in headers where !credentialHeaders.contains(key.lowercased()) {
            out[key.lowercased()] = value
        }
        return out
    }

    /// Append to the client's anthropic-beta list rather than replace it.
    static func mergeAnthropicBeta(into headers: inout [String: String], flag: String) {
        guard let existing = headers["anthropic-beta"] else {
            headers["anthropic-beta"] = flag
            return
        }
        let present = existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !present.contains(flag) { headers["anthropic-beta"] = existing + "," + flag }
    }

    /// Refuses any guest path that could change the host.
    static func pinnedURL(host: String, guestPath: String) -> URL? {
        guard guestPath.hasPrefix("/"), !guestPath.hasPrefix("//"),
              !guestPath.contains("@"), !guestPath.contains("\\"),
              !guestPath.lowercased().contains("://") else { return nil }
        guard let url = URL(string: "https://\(host)\(guestPath)"),
              url.host == host, url.scheme == "https",
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Guest bytes reach the terminal only as printable ASCII.
    static func printable(_ raw: String) -> String {
        String(raw.prefix(200).unicodeScalars.map { (0x20...0x7e).contains($0.value) ? Character($0) : "." })
    }

    // MARK: - Request reading

    static let badGateway = Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8)
    /// The guest picks Content-Length, so cap what it can make us allocate up front.
    static let maxBodyBytes = 32 << 20
    static let maxHeaderBytes = 64 * 1024

    static func readRequest(_ fd: Int32) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 8192)
        while buffer.range(of: separator) == nil {
            let n = scratch.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { return nil }
            buffer.append(contentsOf: scratch[0..<n])
            if buffer.count > maxHeaderBytes { return nil }
        }
        guard let headEnd = buffer.range(of: separator),
              let (method, path, headers) = parseHead(buffer[..<headEnd.lowerBound]) else { return nil }

        var body = Data(buffer[headEnd.upperBound...])
        if let lengthString = headers["content-length"], let length = Int(lengthString), length >= 0 {
            guard length <= maxBodyBytes else { return nil }
            if length > body.count {
                guard let rest = FDIO.readFull(fd, count: length - body.count) else { return nil }
                body.append(contentsOf: rest)
            } else if length < body.count {
                body = Data(body.prefix(length))
            }
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    static func parseHead(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (requestLine[0], requestLine[1], headers)
    }

    /// So a guest that stopped reading fails the write instead of pinning the thread.
    static func setWriteTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Header keys are lowercased.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// Relays the response unbuffered so streams stay live.
private final class ProxyConnection: NSObject, URLSessionDataDelegate {
    private let fd: Int32
    private let done = DispatchSemaphore(value: 0)
    private var wroteHead = false

    init(fd: Int32) { self.fd = fd }

    func wait() { done.wait() }

    /// Never follow a redirect with the credential attached; hand the 3xx back verbatim.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        writeHead(response as? HTTPURLResponse)
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !FDIO.writeAll(fd, Array(data)) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !wroteHead { _ = FDIO.writeAll(fd, Proxy.badGateway) }
        done.signal()
    }

    /// Framing headers are dropped: the body arrives decoded, so they would no longer describe it.
    private func writeHead(_ response: HTTPURLResponse?) {
        guard !wroteHead else { return }
        wroteHead = true
        let status = response?.statusCode ?? 502
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        for (rawKey, value) in response?.allHeaderFields ?? [:] {
            guard let key = rawKey as? String else { continue }
            if ["transfer-encoding", "content-length", "connection", "content-encoding"]
                .contains(key.lowercased()) { continue }
            head += "\(key): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        _ = FDIO.writeAll(fd, Array(head.utf8))
    }
}
