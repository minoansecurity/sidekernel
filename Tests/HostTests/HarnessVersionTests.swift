import Foundation
import Testing
@testable import Host

struct HarnessVersionTests {
    @Test func testParsesVersionOutputOfEachHarness() {
        #expect(Harness.parseVersion("codex-cli 0.160.0\n") == "0.160.0")
        #expect(Harness.parseVersion("2.1.177 (Claude Code)\n") == "2.1.177")
        #expect(Harness.parseVersion("codex-cli 0.161.0-alpha.2") == "0.161.0-alpha.2")
    }

    @Test func testRejectsOutputThatCouldBreakTheInstallScript() {
        #expect(Harness.parseVersion("1.2.3';reboot") == nil)
        #expect(Harness.parseVersion("1.2.3$(id)") == nil)
        #expect(Harness.parseVersion("no version here") == nil)
        #expect(Harness.parseVersion("") == nil)
    }

    @Test func testInstallScriptsPinTheMacVersion() throws {
        let claude = try #require(Harness.invoked(argv0: "sclaude"))
        let codex = try #require(Harness.invoked(argv0: "scodex"))
        #expect(codex.installScript("0.160.0") == "npm install -g @openai/codex@0.160.0")
        #expect(codex.installScript(nil) == "npm install -g @openai/codex@\(Provisioning.Codex.version)")
        #expect(claude.installScript("2.1.177").contains("want='2.1.177-'"))
        #expect(claude.installScript("2.1.177").contains("--allow-downgrades claude-code=\"$v\""))
        #expect(claude.installScript(nil).hasSuffix("apt-get install -y claude-code"))
    }
}
