import Darwin
import Foundation
import Testing
@testable import Host

struct CodexBoundaryTests {
    private func json(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private func expiredLogin(at now: Date) -> Data {
        let payload = json(["exp": now.timeIntervalSince1970 - 1]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return json(["tokens": ["access_token": "header.\(payload).signature",
                                "refresh_token": "one-use-refresh", "account_id": "account"]])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sidekernel-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func defaultAndCustomCredentialDirectoriesAreProtected() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let custom = home.appending(path: ".config/sidekernel-test-codex")
        let homes = [CodexCredentials.defaultHome, custom]
        #expect(CodexCredentials.protectedHomes.contains(CodexCredentials.defaultHome))
        for directory in homes {
            for path in [directory.path, directory.appending(path: "sessions").path] {
                if case .refuse = CLI.hostDirRisk(path, codexHomes: homes) {} else {
                    Issue.record("credential directory must never be shared: \(path)")
                }
            }
        }
        if case .refuse = CLI.hostDirRisk(custom.deletingLastPathComponent().path, codexHomes: homes) {} else {
            Issue.record("a parent of the custom credential directory must be refused")
        }
        let hidden = HomeShare.hidden(codexHomes: homes + [home.appending(path: "archive/codex")])
        #expect(hidden.isSuperset(of: [".codex", ".config", "archive"]))
        if case .refuse = CLI.hostDirRisk(custom.path + "-project", codexHomes: homes) {
            Issue.record("a sibling project does not expose credentials")
        }
    }

    @Test func failedRefreshReloadsAnotherSessionsFreshLogin() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var current = expiredLogin(at: now)
        let fresh = json(["tokens": ["access_token": "fresh-token", "account_id": "account"]])
        var refreshes = 0
        let credentials = CodexCredentials(environment: { [:] }, load: {
            CodexCredentials.Stored(data: current, save: { _ in Issue.record("unexpected write"); return false })
        }, refresh: { _ in
            refreshes += 1
            current = fresh // Native host Codex consumed the refresh token and saved its rotation.
            return nil
        })
        #expect(credentials.resolve(at: now) == .chatGPT(token: "fresh-token", accountID: "account"))
        #expect(credentials.resolve(at: now) == .chatGPT(token: "fresh-token", accountID: "account"))
        #expect(refreshes == 1)
    }

    @Test func hostLogoutOrReloginDuringRefreshTakesPrecedence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for refreshSucceeds in [false, true] {
            for replacement in [nil, json(["OPENAI_API_KEY": "new-account-key"]), json([:])] {
                var current: Data? = expiredLogin(at: now)
                let credentials = CodexCredentials(environment: { [:] }, load: {
                    current.map { CodexCredentials.Stored(data: $0, save: { _ in false }) }
                }, refresh: { _ in
                    current = replacement
                    return refreshSucceeds ? self.json(["access_token": "old-account-rotation"]) : nil
                })
                let expected = replacement.flatMap(CodexCredentials.decode)
                #expect(credentials.resolve(at: now) == expected)
                #expect(credentials.resolve(at: now) == expected)
            }
        }
    }

    @Test func refreshWaitsForAnotherProcessAndReloadsBeforeUsingToken() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = home.appending(path: "auth.json")
        try expiredLogin(at: now).write(to: file)
        let fresh = json(["tokens": ["access_token": "fresh-from-other-process", "account_id": "account"]])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
            import fcntl, pathlib, sys
            home = pathlib.Path(sys.argv[1])
            with (home / '.sidekernel-refresh.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                print('locked', flush=True)
                blob = sys.stdin.readline().strip()
                staged = home / 'replacement.json'
                staged.write_text(blob)
                staged.replace(home / 'auth.json')
                print('updated', flush=True)
                sys.stdin.readline()
            """, home.path]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        #expect(String(data: output.fileHandleForReading.availableData, encoding: .utf8) == "locked\n")
        let loaded = DispatchSemaphore(value: 0), resolved = DispatchSemaphore(value: 0)
        let credentials = CodexCredentials(environment: { [:] }, load: {
            let stored = CodexCredentials.loadHostLogin(home: home)
            loaded.signal()
            return stored
        }, refresh: { _ in Issue.record("must not reuse another process's refresh token"); return nil })
        Thread {
            #expect(credentials.resolve(at: now) == .chatGPT(token: "fresh-from-other-process", accountID: "account"))
            resolved.signal()
        }.start()
        #expect(loaded.wait(timeout: .now() + 5) == .success)
        try input.fileHandleForWriting.write(contentsOf: fresh + Data("\n".utf8))
        #expect(String(data: output.fileHandleForReading.availableData, encoding: .utf8) == "updated\n")
        #expect(resolved.wait(timeout: .now() + 0.1) == .timedOut)
        try input.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
        #expect(resolved.wait(timeout: .now() + 5) == .success)
    }

    @Test func proxyResolvesOnceAndRejectsInvalidPathsBeforeReadingCredentials() throws {
        var loads = 0
        let credentials = CodexCredentials(environment: { [:] }, load: {
            loads += 1
            return CodexCredentials.Stored(data: self.json(["OPENAI_API_KEY": "host-key"]), save: { _ in false })
        })
        let proxy = Proxy(credentials: Credentials(), codex: credentials)
        let valid = HTTPRequest(method: "POST", path: "/codex/responses", headers: [:], body: Data())
        let upstream = try proxy.prepareUpstreamRequest(valid)
        #expect(upstream.value(forHTTPHeaderField: "Authorization") == "Bearer host-key")
        #expect(loads == 1)
        for path in ["/codex/files", "/codex/responses?x=//attacker.invalid@evil"] {
            #expect(proxy.buildUpstreamRequest(HTTPRequest(method: "POST", path: path, headers: [:], body: Data())) == nil)
        }
        #expect(loads == 1)
    }

    @Test func proxyStillReturnsHostLoginGuidanceWithoutCredentials() throws {
        var loads = 0
        let proxy = Proxy(credentials: Credentials(), codex: CodexCredentials(environment: { [:] }, load: {
            loads += 1
            return nil
        }))
        var sockets: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { close(sockets[1]) }
        #expect(FDIO.writeAll(sockets[1], Array("POST /codex/responses HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)))
        proxy.handle(sockets[0]) // closes its end after returning the error
        let response = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false).readDataToEndOfFile()
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(text.contains("Run codex login on the host"))
        #expect(loads == 1)
    }

    @Test func wrapperPreservesArgumentDelimiterAndLiteralPrompt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "codex-stub")
        try "#!/bin/sh\nprintf '%s\\0' \"$@\"\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "guest/codex"), encoding: .utf8)
        let wrapper = directory.appending(path: "wrapper")
        try source.replacingOccurrences(of: "/usr/local/bin/codex", with: binary.path)
            .write(to: wrapper, atomically: true, encoding: .utf8)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        let passthrough = ["exec", "--", "prompt with spaces; $(literal)"]
        child.arguments = [wrapper.path] + passthrough
        child.environment = ["PATH": "/usr/bin:/bin", "CODEX_HOME": directory.appending(path: "config").path,
                             "SK_ROOT": directory.path]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        let arguments = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        #expect(arguments.prefix(2) == ["-c", "model_provider=\"sidekernel\""])
        #expect(Array(arguments.suffix(passthrough.count)) == passthrough)
    }
}
