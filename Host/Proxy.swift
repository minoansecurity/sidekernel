import Foundation
import Darwin

/// Forwards guest inference requests to pinned upstreams with host credentials injected.
public final class Proxy {
    private let credentials: Credentials
    private let codex: CodexCredentials
    private let session: URLSession

    public convenience init(credentials: Credentials) {
        self.init(credentials: credentials, codex: CodexCredentials())
    }

    init(credentials: Credentials, codex: CodexCredentials) {
        self.credentials = credentials
        self.codex = codex
        let cfg = URLSessionConfiguration.ephemeral
        // Not timeoutIntervalForResource, which would cap long streaming generations.
        cfg.timeoutIntervalForRequest = 60
        cfg.httpShouldSetCookies = false
        self.session = URLSession(configuration: cfg)
    }

    /// One request per connection.
    public func handle(_ fd: Int32) {
        defer { close(fd) }
        FDIO.setReadTimeout(fd, seconds: 10)
        Self.setWriteTimeout(fd, seconds: 30)
        guard let request = Self.readRequest(fd) else { return }
        let upstream: URLRequest
        do { upstream = try prepareUpstreamRequest(request) }
        catch RequestError.codexLoginRequired {
            _ = FDIO.writeAll(fd, Array(Self.codexLoginRequired.utf8))
            return
        }
        catch {
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

    enum RequestError: Error { case refused, codexLoginRequired }

    static let probeMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]

    /// Bodyless idempotent requests are base-URL probes, not channel misuse worth surfacing.
    static func isNotableRefusal(_ request: HTTPRequest) -> Bool {
        !request.body.isEmpty || !probeMethods.contains(request.method.uppercased())
    }

    func buildUpstreamRequest(_ request: HTTPRequest) -> URLRequest? {
        try? prepareUpstreamRequest(request)
    }

    func prepareUpstreamRequest(_ request: HTTPRequest) throws -> URLRequest {
        if request.path.hasPrefix(Contract.codexProxyPath + "/") {
            return try buildCodexRequest(request)
        }
        let pathOnly = String(request.path.prefix { $0 != "?" })
        guard Self.allowedPaths.contains(pathOnly) else {
            if Self.isNotableRefusal(request) {
                Terminal.notice("proxy refused \(Self.printable(request.method)) \(Self.printable(request.path))")
            }
            throw RequestError.refused
        }
        guard let injection = credentials.resolveAnthropic(),
              let url = Self.pinnedURL(host: Self.upstreamHost, guestPath: request.path)
        else { throw RequestError.refused }

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

    /// Exact method/path pairs only: the guest cannot use host auth on other APIs.
    func buildCodexRequest(_ request: HTTPRequest) throws -> URLRequest {
        let path = String(request.path.dropFirst(Contract.codexProxyPath.count))
        let pathOnly = String(path.prefix { $0 != "?" })
        guard (request.method == "POST" && ["/responses", "/responses/compact"].contains(pathOnly))
            || (request.method == "GET" && pathOnly == "/models") else { throw RequestError.refused }
        guard Self.pinnedURL(host: "api.openai.com", guestPath: path) != nil else { throw RequestError.refused }
        guard let login = codex.resolve() else { throw RequestError.codexLoginRequired }
        var headers = Self.stripCredentialHeaders(request.headers)
        for managed in ["host", "content-length", "connection", "accept-encoding", "chatgpt-account-id",
                        "openai-organization", "openai-project", "cookie", "proxy-authorization"] {
            headers[managed] = nil
        }
        let host: String, upstreamPath: String, bearer: String
        switch login {
        case .apiKey(let key):
            host = "api.openai.com"
            upstreamPath = "/v1" + path
            bearer = key
        case .chatGPT(let token, let accountID):
            host = "chatgpt.com"
            upstreamPath = "/backend-api/codex" + path
            bearer = token
            if let accountID, !accountID.isEmpty { headers["chatgpt-account-id"] = accountID }
            headers["originator"] = "codex_cli_rs"
        }
        guard let url = Self.pinnedURL(host: host, guestPath: upstreamPath) else { throw RequestError.refused }
        headers["authorization"] = "Bearer \(bearer)"
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
    static let codexLoginRequired = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        + #"{"error":{"message":"Run codex login on the host, or set OPENAI_API_KEY on the host.","type":"authentication_error"}}"#
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
