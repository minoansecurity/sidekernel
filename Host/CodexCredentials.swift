import CryptoKit
import Foundation
import Security

/// Read and refresh the host's Codex login. Nothing from this store is shared with the VM.
final class CodexCredentials: @unchecked Sendable {
    enum Login: Equatable {
        case apiKey(String)
        case chatGPT(token: String, accountID: String?)
    }

    struct Stored {
        let data: Data
        let save: (Data) -> Bool
    }

    static var hostHome: URL {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (configured.isEmpty ? home.appending(path: ".codex") : URL(fileURLWithPath: configured))
            .resolvingSymlinksInPath()
    }

    static let keychainService = "Codex Auth"
    static func keychainAccount(home: URL) -> String {
        let digest = SHA256.hash(data: Data(home.resolvingSymlinksInPath().path.utf8))
        return "cli|" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private let environment: () -> [String: String]
    private let load: () -> Stored?
    private let refresh: (String) -> Data?
    private let lock = NSLock()
    private var consumed: Data?
    private var cached: Data?
    private var lastFailure: Date?

    init(environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         load: @escaping () -> Stored? = { CodexCredentials.loadHostLogin() },
         refresh: @escaping (String) -> Data? = { CodexCredentials.requestRefresh($0) }) {
        self.environment = environment
        self.load = load
        self.refresh = refresh
    }

    /// Used by doctor; never refreshes or writes a credential.
    func hasCredential() -> Bool {
        environmentKey() != nil || load().flatMap { Self.decode($0.data) } != nil
    }

    /// Re-read on every request, so host logout/re-login takes effect in a running VM.
    func resolve(at now: Date = Date()) -> Login? {
        lock.lock()
        defer { lock.unlock() }
        if let key = environmentKey() { return .apiKey(key) }
        guard let stored = load() else {
            consumed = nil; cached = nil; lastFailure = nil
            return nil
        }
        if stored.data != consumed && stored.data != cached {
            consumed = stored.data; cached = nil; lastFailure = nil
        }
        let data = cached ?? stored.data
        guard let login = Self.decode(data) else { return nil }
        guard case .chatGPT(let token, _) = login,
              Self.needsRefresh(data, token: token, at: now),
              let top = Self.object(data), let tokens = top["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty
        else { return login }
        if let lastFailure, now.timeIntervalSince(lastFailure) < 30 { return login }
        guard let response = refresh(refreshToken),
              let rotated = Self.rotatedBlob(data, response: response, at: now),
              let fresh = Self.decode(rotated) else {
            lastFailure = now
            return login
        }
        consumed = stored.data
        cached = rotated
        lastFailure = nil
        if !stored.save(rotated) {
            Terminal.notice("Codex login write-back failed; run codex login on the host before your next session")
        }
        return fresh
    }

    private func environmentKey() -> String? {
        let env = environment()
        for name in ["CODEX_API_KEY", "OPENAI_API_KEY"] {
            if let key = env[name], !key.isEmpty { return key }
        }
        return nil
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decode(_ data: Data) -> Login? {
        guard let top = object(data) else { return nil }
        let mode = top["auth_mode"] as? String
        if let mode, !["apikey", "chatgpt", "chatgptAuthTokens"].contains(mode) { return nil }
        if mode != "chatgpt", mode != "chatgptAuthTokens",
           let key = top["OPENAI_API_KEY"] as? String, !key.isEmpty { return .apiKey(key) }
        if mode == "apikey" { return nil }
        guard let tokens = top["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        let claims = jwtClaims(tokens["id_token"] as? String ?? token)
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        return .chatGPT(token: token, accountID: tokens["account_id"] as? String
            ?? auth?["chatgpt_account_id"] as? String)
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 3 {
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let decoded = Data(base64Encoded: payload) { return object(decoded) }
        }
        return nil
    }

    static func needsRefresh(_ data: Data, token: String, at now: Date) -> Bool {
        if let exp = jwtClaims(token)?["exp"] as? Double {
            return now.timeIntervalSince1970 >= exp - 300
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        guard let stamp = object(data)?["last_refresh"] as? String,
              let refreshed = ISO8601DateFormatter().date(from: stamp) ?? fractional.date(from: stamp) else { return false }
        return now.timeIntervalSince(refreshed) >= 8 * 86_400
    }

    static func rotatedBlob(_ data: Data, response: Data, at now: Date) -> Data? {
        guard var top = object(data), var tokens = top["tokens"] as? [String: Any],
              let reply = object(response), let access = reply["access_token"] as? String,
              !access.isEmpty else { return nil }
        tokens["access_token"] = access
        for field in ["refresh_token", "id_token"] {
            if let value = reply[field] as? String, !value.isEmpty { tokens[field] = value }
        }
        top["tokens"] = tokens
        top["last_refresh"] = ISO8601DateFormatter().string(from: now)
        return try? JSONSerialization.data(withJSONObject: top)
    }

    /// Use file storage by default, as Codex does; keyring/auto select its direct Keychain item.
    static func loadHostLogin(home: URL = hostHome) -> Stored? {
        let config = (try? String(contentsOf: home.appending(path: "config.toml"), encoding: .utf8)) ?? ""
        // Only the top-level setting, before any TOML table. Never execute host config.
        let topLevel = config.components(separatedBy: .newlines).prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        let mode = topLevel.compactMap { line -> String? in
            let pattern = #"^\s*cli_auth_credentials_store\s*=\s*["'](file|keyring|auto|ephemeral)["']\s*(?:#.*)?$"#
            guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
            let value = String(line[range]).components(separatedBy: "=").last ?? ""
            return value.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "\"" || $0 == "'" }).first.map(String.init)
        }.first ?? "file"
        if mode == "ephemeral" { return nil }
        if mode == "keyring" || mode == "auto" {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount(home: home)]
            var read = query
            read[kSecReturnData as String] = true
            var result: CFTypeRef?
            if SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return Stored(data: data, save: { blob in
                    var current: CFTypeRef?
                    guard SecItemCopyMatching(read as CFDictionary, &current) == errSecSuccess,
                          current as? Data == data else { return false }
                    return SecItemUpdate(query as CFDictionary, [kSecValueData as String: blob] as CFDictionary) == errSecSuccess
                })
            }
            if mode == "keyring" { return nil }
        }
        let file = home.appending(path: "auth.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return Stored(data: data, save: { blob in
            // A host re-login during the network request must not be overwritten.
            guard (try? Data(contentsOf: file)) == data else { return false }
            do {
                // Create the replacement with owner-only access before putting any secret in it.
                let staged = home.appending(path: ".auth-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: staged) }
                guard FileManager.default.createFile(atPath: staged.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else { return false }
                try blob.write(to: staged)
                guard (try? Data(contentsOf: file)) == data else { return false }
                return rename(staged.path, file.path) == 0
            }
            catch { return false }
        })
    }

    private static func requestRefresh(_ token: String) -> Data? {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token",
            "refresh_token": token, "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"])
        let delegate = NoRedirect()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        session.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
