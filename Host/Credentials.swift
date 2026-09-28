import Foundation

public enum Injection: Sendable { case apiKey(String), oauthBearer(String) }

public struct Credentials: Sendable {
    static let keychainService = "Claude Code-credentials"
    /// Every OAuth request must carry this, refresh included.
    static let oauthBetaFlag = "oauth-2025-04-20"

    private let refresher = OAuthRefresher()

    public init() {}

    /// Resolved per call, so a login made mid-session serves the next request.
    public func resolveAnthropic() -> Injection? {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return .apiKey(key)
        }
        guard let (stored, rawBlob) = Self.storedLogin() else { return nil }
        if stored.isExpiring(at: Date()),
           let fresh = refresher.freshToken(for: stored, rawBlob: rawBlob) {
            return .oauthBearer(fresh)
        }
        // No refresh possible: send the stale token and let the upstream's 401 answer.
        return .oauthBearer(stored.accessToken)
    }

    /// Decides whether the guest gets the placeholder.
    public func hasAnthropicCredential() -> Bool {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return true
        }
        return Self.storedLogin() != nil
    }

    // MARK: - Adoption

    /// On ok, the guest swaps its own copy for the placeholder.
    public func adopt(blob: [UInt8]) -> Frame {
        if let rejection = Self.adoptionRejection(for: blob) { return rejection }
        guard Self.securityWrite(service: Self.keychainService, account: NSUserName(), data: Data(blob)) else {
            return .ctlReply(status: .err,
                             message: "Keychain store failed; the sandbox login file was left in place",
                             payload: [])
        }
        return .ctlReply(status: .ok, message: "", payload: [])
    }

    /// Checked before anyone is prompted, so junk and the placeholder are refused silently.
    public static func adoptionRejection(for blob: [UInt8]) -> Frame? {
        let data = Data(blob)
        if data == Contract.placeholderBlob {
            return .ctlReply(status: .deny, message: "placeholder credential refused", payload: [])
        }
        if !isClaudeLoginShaped(data) {
            return .ctlReply(status: .err, message: "not a Claude credential", payload: [])
        }
        return nil
    }

    private static func isClaudeLoginShaped(_ data: Data) -> Bool {
        struct Stored: Decodable {
            struct OAuth: Decodable { let accessToken: String }
            let claudeAiOauth: OAuth
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        return !stored.claudeAiOauth.accessToken.isEmpty
    }

    /// The raw blob comes back too, so a refresh can rotate only the tokens.
    static func storedLogin() -> (credentials: OAuthCredentials, rawBlob: Data)? {
        guard let data = securityRead(service: keychainService) else { return nil }
        struct Stored: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let refreshToken: String?
                let expiresAt: Double?
            }
            let claudeAiOauth: OAuth
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.claudeAiOauth.accessToken.isEmpty else { return nil }
        let oauth = stored.claudeAiOauth
        return (OAuthCredentials(accessToken: oauth.accessToken,
                                 refreshToken: oauth.refreshToken,
                                 expiresAt: oauth.expiresAt), data)
    }

    // MARK: - Keychain via /usr/bin/security

    /// The secret comes off the tool's stdout, never argv.
    static func securityRead(service: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Drain to EOF, then wait: reading first cannot deadlock on a full pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        var bytes = data
        if bytes.last == 0x0a { bytes.removeLast() }
        return bytes.isEmpty ? nil : bytes
    }

    /// Longest command `security -i` reads from one stdin line.
    static let securityLineLimit = 4096

    /// The same binary Claude Code uses, so the item's access list stays as found.
    /// The secret goes hex-encoded over stdin; in argv, `ps` would show it.
    static func securityWrite(service: String, account: String, data: Data) -> Bool {
        let unquotable = CharacterSet(charactersIn: "\"\\\n\r")
        guard service.rangeOfCharacter(from: unquotable) == nil,
              account.rangeOfCharacter(from: unquotable) == nil else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        guard command.utf8.count < securityLineLimit else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        input.fileHandleForWriting.write(Data(command.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        // Interactive mode can exit 0 past a failed command, so the stored value is what counts.
        return p.terminationStatus == 0 && securityRead(service: service) == data
    }
}

struct OAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    /// Epoch milliseconds, as Claude Code stores it; nil means non-expiring.
    let expiresAt: Double?

    /// Renew early, so a token never expires mid-request.
    static let expiryMargin: TimeInterval = 300

    func isExpiring(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return Self.isExpiring(expiresAt: expiresAt, at: date)
    }

    static func isExpiring(expiresAt: Double, at date: Date) -> Bool {
        date.timeIntervalSince1970 >= expiresAt / 1000 - expiryMargin
    }
}

/// One refresh at a time: a refresh token can be spent only once.
final class OAuthRefresher: @unchecked Sendable {
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// After a failed refresh, use the stale token this long instead of retrying per request.
    static let failureBackoff: TimeInterval = 30

    struct Refreshed {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
    }

    private let lock = NSLock()
    private var cached: Refreshed?
    /// Tells our own rotation apart from a host re-login.
    private var lastConsumedRefreshToken: String?
    private var lastFailure: Date?

    func freshToken(for stored: OAuthCredentials, rawBlob: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }

        // A token we neither spent nor issued: the host re-logged in, so trust it.
        if let cached, let storedToken = stored.refreshToken,
           storedToken != lastConsumedRefreshToken, storedToken != cached.refreshToken {
            self.cached = nil
            lastFailure = nil
        }
        if let cached, !OAuthCredentials.isExpiring(expiresAt: cached.expiresAt, at: Date()) {
            return cached.accessToken
        }
        // Prefer our rotated token: the Keychain can still show the one we rotated past.
        guard let refreshToken = cached?.refreshToken ?? stored.refreshToken else { return nil }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < Self.failureBackoff {
            return nil
        }

        guard let response = requestRefresh(refreshToken: refreshToken) else {
            lastFailure = Date()
            return nil
        }
        lastFailure = nil
        lastConsumedRefreshToken = refreshToken
        let rotated = Refreshed(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? refreshToken,
            expiresAt: (Date().timeIntervalSince1970 + response.expires_in) * 1000)
        cached = rotated
        writeBack(rawBlob: rawBlob, rotated: rotated)
        return rotated.accessToken
    }

    private func writeBack(rawBlob: Data, rotated: Refreshed) {
        if let blob = Self.rotatedBlob(from: rawBlob, refreshed: rotated),
           Credentials.securityWrite(service: Credentials.keychainService,
                                     account: NSUserName(), data: blob) { return }
        Terminal.notice("Keychain write-back failed; the host Claude login may need one re-login")
    }

    static func rotatedBlob(from raw: Data, refreshed: Refreshed) -> Data? {
        guard var top = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              var oauth = top["claudeAiOauth"] as? [String: Any] else { return nil }
        oauth["accessToken"] = refreshed.accessToken
        oauth["refreshToken"] = refreshed.refreshToken
        oauth["expiresAt"] = refreshed.expiresAt
        top["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: top)
    }

    // MARK: - Wire protocol

    private struct RefreshResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }

    private func requestRefresh(refreshToken: String) -> RefreshResponse? {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Credentials.oauthBetaFlag, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        guard let (data, status) = Self.blockingFetch(request), status == 200,
              let response = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              !response.access_token.isEmpty else { return nil }
        return response
    }

    /// Blocking: the callers are plain worker threads.
    private static func blockingFetch(_ request: URLRequest) -> (Data, Int)? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data, Int)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse {
                result = (data, http.statusCode)
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
