import Foundation
import Testing
@testable import Host

struct CodexTests {
    private func json(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private func login(_ token: String = "host-access", refresh: String = "host-refresh") -> Data {
        json(["tokens": ["access_token": token, "refresh_token": refresh,
                         "id_token": "host-id", "account_id": "host-account"],
              "last_refresh": ISO8601DateFormatter().string(from: Date()), "extra": "preserved"])
    }

    private func jwt(expires: Date) -> String {
        let payload = json(["exp": expires.timeIntervalSince1970]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func credentials(_ data: Data?) -> CodexCredentials {
        CodexCredentials(environment: { [:] }, load: {
            data.map { CodexCredentials.Stored(data: $0, save: { _ in Issue.record("unexpected write"); return false }) }
        }, refresh: { _ in Issue.record("unexpected refresh"); return nil })
    }

    private func proxy(_ data: Data?) -> Proxy {
        Proxy(credentials: Credentials(), codex: credentials(data))
    }

    private func request(_ path: String = "/codex/responses", method: String = "POST") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: ["authorization": "Bearer guest-token",
            "x-api-key": "guest-key", "host": "attacker.invalid", "content-length": "999",
            "cookie": "guest-cookie", "proxy-authorization": "guest-proxy",
            "chatgpt-account-id": "guest-account", "openai-organization": "guest-org",
            "openai-project": "guest-project", "content-type": "application/json"],
            body: json(["model": "test-model", "stream": true, "store": false, "input": []]))
    }

    @Test func testAPIKeyUsesPinnedOpenAIHostAndRemovesGuestCredentials() throws {
        let incoming = request()
        let upstream = try #require(proxy(json(["OPENAI_API_KEY": "host-key"])).buildUpstreamRequest(incoming))
        #expect(upstream.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(upstream.value(forHTTPHeaderField: "Authorization") == "Bearer host-key")
        #expect(upstream.httpBody == incoming.body)
        for header in ["x-api-key", "host", "content-length", "cookie", "proxy-authorization",
                       "chatgpt-account-id", "openai-organization", "openai-project"] {
            #expect(upstream.value(forHTTPHeaderField: header) == nil, Comment(rawValue: header))
        }
    }

    @Test func testChatGPTUsesPinnedCodexBackendAndHostAccount() throws {
        let upstream = try #require(proxy(login()).buildUpstreamRequest(request("/codex/responses?client_version=0.159.2")))
        #expect(upstream.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses?client_version=0.159.2")
        #expect(upstream.value(forHTTPHeaderField: "Authorization") == "Bearer host-access")
        #expect(upstream.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "host-account")
        #expect(upstream.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
        #expect(upstream.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func testAllowlistRejectsOtherAPIsMethodsAndTraversal() {
        let proxy = proxy(login())
        for path in ["/codex", "/codex/v1/responses", "/codex/files", "/codex/oauth/token",
                     "/codex/responses/../files", "/codex/%72esponses", "/codex//responses",
                     "/codex/responses%2f..%2ffiles", "/codex/responses?x=//attacker.invalid@evil"] {
            #expect(proxy.buildUpstreamRequest(request(path)) == nil, Comment(rawValue: path))
        }
        #expect(proxy.buildUpstreamRequest(request(method: "DELETE")) == nil)
        #expect(proxy.buildUpstreamRequest(request(method: "GET")) == nil)
        #expect(proxy.buildUpstreamRequest(request("/codex/models")) == nil)
        #expect(proxy.buildUpstreamRequest(request("/codex/models", method: "GET")) != nil)
        #expect(proxy.buildUpstreamRequest(request("/codex/responses/compact")) != nil)
    }

    @Test func testMissingAndMalformedCredentialsFailClosed() {
        for data in [nil, Data(), json([:]), json(["tokens": ["access_token": ""]]),
                     json(["OPENAI_API_KEY": ""])] {
            #expect(proxy(data).buildUpstreamRequest(request()) == nil)
            #expect(!(credentials(data).hasCredential()))
        }
    }

    @Test func testEnvironmentAPIKeyTakesPrecedenceWithoutLoadingLogin() {
        let credentials = CodexCredentials(environment: { ["OPENAI_API_KEY": "host-env"] },
            load: { Issue.record("should not load login"); return nil })
        #expect(credentials.hasCredential())
        #expect(credentials.resolve() == .apiKey("host-env"))
    }

    @Test func testStoredAuthModeChoosesTheHostLoginAndRejectsUnsupportedModes() throws {
        var top = try #require(CodexCredentials.object(login()))
        top["OPENAI_API_KEY"] = "stale-key"
        top["auth_mode"] = "chatgpt"
        #expect(CodexCredentials.decode(json(top)) == .chatGPT(token: "host-access", accountID: "host-account"))
        top["auth_mode"] = "apikey"
        #expect(CodexCredentials.decode(json(top)) == .apiKey("stale-key"))
        top["auth_mode"] = "bedrockApiKey"
        #expect(CodexCredentials.decode(json(top)) == nil)
    }

    @Test func testGuestEnvironmentDoesNotForwardHostSecretsOrCodexHome() {
        let secrets = ["OPENAI_API_KEY": "real-api-key", "CODEX_API_KEY": "real-codex-key",
                       "CODEX_ACCESS_TOKEN": "real-access", "CODEX_HOME": "/host/secret-home",
                       "ANTHROPIC_API_KEY": "real-anthropic-key"]
        let env = Sandbox.shellEnvironment(routeAnthropic: true, anthropicAuthenticated: true,
                                          hostDir: "/project", hostEnv: secrets)
        #expect(env.contains("CODEX_HOME=/run/sk-project/codex"))
        for value in secrets.values { #expect(!(env.contains { $0.contains(value) })) }
    }

    @Test func testRefreshRotatesOnlyTokensAndPreservesAccountAndOtherFields() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = login(jwt(expires: now.addingTimeInterval(-1)))
        var current = expired
        var refreshes = 0
        let fresh = jwt(expires: now.addingTimeInterval(3600))
        let credentials = CodexCredentials(environment: { [:] }, load: {
            CodexCredentials.Stored(data: current, save: { current = $0; return true })
        }, refresh: { token in
            #expect(token == "host-refresh")
            refreshes += 1
            return self.json(["access_token": fresh, "refresh_token": "rotated-refresh"])
        })
        #expect(credentials.hasCredential())
        #expect(refreshes == 0, Comment(rawValue: "doctor must not refresh"))
        #expect(credentials.resolve(at: now) == .chatGPT(token: fresh, accountID: "host-account"))
        #expect(credentials.resolve(at: now) == .chatGPT(token: fresh, accountID: "host-account"))
        #expect(refreshes == 1)
        let top = try #require(CodexCredentials.object(current))
        #expect(top["extra"] as? String == "preserved")
        let tokens = try #require(top["tokens"] as? [String: String])
        #expect(tokens["id_token"] == "host-id")
        #expect(tokens["refresh_token"] == "rotated-refresh")
    }

    @Test func testRefreshFailureBackoffAndHostReloginAndLogout() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredToken = jwt(expires: now.addingTimeInterval(-1))
        var current: Data? = login(expiredToken)
        var attempts = 0
        let credentials = CodexCredentials(environment: { [:] }, load: {
            current.map { CodexCredentials.Stored(data: $0, save: { _ in false }) }
        }, refresh: { _ in attempts += 1; return nil })
        #expect(credentials.resolve(at: now) == .chatGPT(token: expiredToken, accountID: "host-account"))
        _ = credentials.resolve(at: now.addingTimeInterval(1))
        #expect(attempts == 1)
        current = json(["OPENAI_API_KEY": "new-host-key"])
        #expect(credentials.resolve(at: now) == .apiKey("new-host-key"))
        current = nil
        #expect(credentials.resolve(at: now) == nil)
    }

    @Test func testFailedWriteBackKeepsRotatedTokenUntilHostLogout() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var current: Data? = login(jwt(expires: now.addingTimeInterval(-1)))
        let fresh = jwt(expires: now.addingTimeInterval(3600))
        var refreshes = 0
        let credentials = CodexCredentials(environment: { [:] }, load: {
            current.map { CodexCredentials.Stored(data: $0, save: { _ in false }) }
        }, refresh: { _ in refreshes += 1; return self.json(["access_token": fresh]) })
        _ = credentials.resolve(at: now)
        #expect(credentials.resolve(at: now) == .chatGPT(token: fresh, accountID: "host-account"))
        #expect(refreshes == 1)
        current = nil
        #expect(credentials.resolve(at: now) == nil)
    }

    @Test func testFileStorageRefreshIsPrivateAndDoesNotOverwriteRelogin() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "sidekernel-auth-test-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "auth.json")
        try login().write(to: file)
        let stored = try #require(CodexCredentials.loadHostLogin(home: home))
        let rotated = json(["OPENAI_API_KEY": "new-key"])
        #expect(stored.save(rotated))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(!(stored.save(login())), Comment(rawValue: "cannot overwrite a host re-login"))
        #expect(try Data(contentsOf: file) == rotated)
        try "cli_auth_credentials_store = 'ephemeral'\n".write(to: home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        #expect(CodexCredentials.loadHostLogin(home: home) == nil)
    }

    @Test func testCodexInvocationAndHomeShareExcludeCredentials() throws {
        let agent = try #require(Agent.invoked(argv0: "/opt/homebrew/bin/scodex"))
        let args = ["exec", "prompt with spaces; $(literal)", "--model", "test-model"]
        #expect(agent.launchCommand(args) == ["codex"] + args)
        #expect(HomeShare.hidden.contains(".codex"))
        if case .refuse = CLI.hostDirRisk(CodexCredentials.hostHome.path) {} else {
            Issue.record("must refuse sharing host credentials")
        }
    }
}
