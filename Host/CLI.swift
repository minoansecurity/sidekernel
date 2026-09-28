import Foundation
import Darwin

@main
public enum CLI {
    static let version = "0.1.0"

    public static func main() {
        if let agent = Agent.invoked(argv0: CommandLine.arguments.first ?? "") {
            exit(runAgent(agent, passthrough: Array(CommandLine.arguments.dropFirst())))
        }
        switch CommandLine.arguments.dropFirst().first {
        case nil: exit(runShell())
        case "install": exit(runInstall())
        case "doctor": exit(runDoctor())
        case "saved": exit(runSaved())
        case "--version", "version": print("sidekernel \(version)")
        case "--help", "-h", "help": print(usage)
        case let word?:
            FileHandle.standardError.write(Data("unknown command: \(word)\n\n\(usage)\n".utf8))
            exit(64)
        }
    }

    // MARK: - Launch

    static func runShell() -> Int32 {
        do {
            try Agent.provisionDetected()
            return try launch(command: nil)
        } catch { return fail(error) }
    }

    /// On 127 (command not found), installs the agent and retries once.
    static func runAgent(_ agent: Agent, passthrough: [String]) -> Int32 {
        do {
            try Agent.provisionDetected()
            var code = try launch(command: agent.launchCommand(passthrough))
            if code == 127 {
                guard try Agent.provision(agent) == 0 else { return 1 }
                code = try launch(command: agent.launchCommand(passthrough))
            }
            return code
        } catch { return fail(error) }
    }

    static func launch(command: [String]?) throws -> Int32 {
        let options = SandboxOptions(
            hostDir: FileManager.default.currentDirectoryPath, command: command,
            networkOn: networkOn, waitForNetwork: false, quiet: false)
        return try Sandbox(options: options, artifacts: provisionOnce(),
                           credentials: Credentials()).run()
    }

    /// Any non-empty SK_NO_NETWORK, even "0", boots offline.
    static var networkOn: Bool {
        (ProcessInfo.processInfo.environment["SK_NO_NETWORK"] ?? "").isEmpty
    }

    static func provisionOnce() throws -> Artifacts {
        let steps = Terminal.Steps()
        do {
            let artifacts = try Provisioning().ensureAll(steps: steps)
            steps.finish()
            return artifacts
        } catch {
            steps.finish(ok: false)
            throw error
        }
    }

    // MARK: - Subcommands

    /// argv[0] selects the agent, so every command is a symlink to this binary.
    static func runInstall() -> Int32 {
        let fm = FileManager.default
        let binary = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")).resolvingSymlinksInPath()
        guard fm.fileExists(atPath: binary.path) else {
            return fail(SidekernelError.provisioning("cannot locate the sidekernel binary"))
        }
        let binDir = fm.homeDirectoryForCurrentUser.appending(path: ".local/bin")
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            let names = ["sidekernel", "sk"] + Agent.table.map(\.argv0)
            for name in names {
                let link = binDir.appending(path: name)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: binary)
            }
            print("\(Terminal.accent)✓\(Terminal.reset) installed \(names.count) commands → \(binDir.path)")
            print("  \(Terminal.dim)\(names.joined(separator: " · "))\(Terminal.reset)")
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").contains { $0 == binDir.path }
            if !onPath {
                print("  \(Terminal.dim)add it to your PATH:  echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc\(Terminal.reset)")
            }
            return 0
        } catch { return fail(error) }
    }

    static func runDoctor() -> Int32 {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let machine = "Apple Silicon"
        let machineOK = os.majorVersion >= 26
        #else
        let machine = "x86_64 (unsupported, Apple Silicon required)"
        let machineOK = false
        #endif
        let ram = ProcessInfo.processInfo.physicalMemory >> 30
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: ".sidekernel")
        let kernel = fm.fileExists(atPath: root.appending(path: "kernel/vmlinux").path)
        let base = fm.fileExists(atPath: root.appending(path: "images/sidekernel-base.img").path)
        let personal = PersonalStore(directory: root).currentImage() != nil
        let login = Credentials().hasAnthropicCredential()
        // Two installs (say `make install` in ~/.local/bin and Homebrew): the first on PATH wins.
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        let installs = (["sidekernel", "sk"] + Agent.table.map(\.argv0)).flatMap { name in
            dirs.map { "\($0)/\(name)" }.filter { fm.isExecutableFile(atPath: $0) }
        }
        let targets = Set(installs.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent().path
        })
        let installsOK = targets.count <= 1

        func line(_ ok: Bool, _ text: String) -> String {
            "  \(ok ? "\(Terminal.accent)✓" : "\(Terminal.red)✗")\(Terminal.reset) \(text)"
        }
        print("""
        sidekernel \(version)
        \(line(machineOK, "macOS \(os.majorVersion).\(os.minorVersion) on \(machine)\(os.majorVersion >= 26 ? "" : " (requires macOS 26+)")"))
        \(line(ram >= 8, "memory: \(ram) GB\(ram >= 8 ? "" : " (8 GB minimum recommended)")"))
        \(line(true, "kernel: \(kernel ? "cached" : "fetched on first run")"))
        \(line(true, "base image: \(base ? "built" : "built on first run")"))
        \(line(true, "personal layer: \(personal ? "present" : "none yet (`save` inside a sandbox creates it)")"))
        \(line(installsOK, installsOK ? "one install on PATH" : "installed more than once, the first on PATH wins: \(targets.sorted().joined(separator: ", "))"))
        \(line(true, "Claude login: \(login ? "in Keychain (read-only check)" : "none (/login on the host or inside a sandbox)")"))
        """)
        return machineOK ? 0 : 1
    }

    static func runSaved() -> Int32 {
        let store = PersonalStore(directory:
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".sidekernel"))
        do {
            let listing = try store.listing()
            guard !listing.entries.isEmpty else {
                print("\(Terminal.dim)Nothing saved yet.\(Terminal.reset)")
                print("\(Terminal.dim)Inside a sandbox, install or change something, then run `save`.\(Terminal.reset)")
                return 0
            }
            print("")
            print("  \(Terminal.accent)Saved in your personal layer\(Terminal.reset) "
                + "\(Terminal.dim)(\(listing.total) total, inherited by every sandbox)\(Terminal.reset)")
            print("")
            for entry in listing.entries {
                let size = entry.size.padding(toLength: max(6, entry.size.count), withPad: " ", startingAt: 0)
                print("  \(Terminal.dim)· \(size)\(Terminal.reset)  \(entry.path)")
            }
            print("")
            return 0
        } catch {
            print("\(Terminal.dim)\(message(for: error))\(Terminal.reset)")
            return 0
        }
    }

    // MARK: - Errors

    static func fail(_ error: Error) -> Int32 {
        FileHandle.standardError.write(Data(
            "\(Terminal.red)✗\(Terminal.reset) \(message(for: error))\n".utf8))
        return 1
    }

    static func message(for error: Error) -> String {
        (error as? SidekernelError)?.description ?? error.localizedDescription
    }

    static let usage = """
    SideKernel: sandboxed AI coding agents on macOS. A directory is a sandbox.

    usage:
      sidekernel            ephemeral sandbox shell in this directory

      sidekernel install    put sk + the agent commands on your PATH
      sidekernel doctor     side-effect-free health report
      sidekernel saved      what `save` kept in your personal layer

      sclaude [args…]       Claude Code in this directory's sandbox (args pass through)

    SK_NO_NETWORK=1 boots pinned: no internet/LAN, Claude API keeps working.
    Inside a sandbox: save · sk-drop <host path> · sk-net on|off|status
    """
}

public enum SidekernelError: Error, CustomStringConvertible {
    case provisioning(String), vm(String), agentProtocol(String), timeout(String)

    public var description: String {
        switch self {
        case .provisioning(let m): return m
        case .vm(let m): return m
        case .agentProtocol(let m): return "agent protocol: \(m)"
        case .timeout(let m): return "timed out: \(m)"
        }
    }
}

struct Agent {
    let argv0: String
    let name: String
    let binary: String
    let installScript: String
    let homeMarkers: [String]
    let seedScript: String?
    let autoProvision: Bool

    static let table: [Agent] = [
        Agent(argv0: "sclaude", name: "Claude Code", binary: "claude",
              installScript: "{ apt-get update || { rm -rf /var/lib/apt/lists/* && apt-get update; }; } || true; "
                  + "DEBIAN_FRONTEND=noninteractive apt-get install -y claude-code",
              homeMarkers: [".claude.json", ".claude"],
              seedScript: "[ -e \"$HOME/.claude.json\" ] || printf '%s' "
                  + "'\(Onboarding.firstRunStateJSON)' > \"$HOME/.claude.json\"",
              autoProvision: true),
    ]

    static func invoked(argv0: String) -> Agent? {
        let name = (argv0 as NSString).lastPathComponent
        return table.first { $0.argv0 == name }
    }

    func launchCommand(_ passthrough: [String]) -> [String] {
        let argv = [binary] + passthrough
        guard let seedScript else { return argv }
        let exec = (["exec"] + argv).map(Self.singleQuoted).joined(separator: " ")
        return ["/bin/sh", "-c", "\(seedScript); \(exec)"]
    }

    static func singleQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Provisioning

    static func provisionDetected() throws {
        guard CLI.networkOn, canBootVM else { return }
        for agent in table where agent.autoProvision {
            guard !FileManager.default.fileExists(atPath: agent.provisionMarker.path),
                  agent.isOnHost(), retryDue(after: agent.lastFailure) else { continue }
            try provision(agent)
        }
    }

    static var canBootVM: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        #else
        return false
        #endif
    }

    static func retryDue(after lastFailure: Date?) -> Bool {
        guard let lastFailure else { return true }
        return Date().timeIntervalSince(lastFailure) >= 86_400
    }

    func isOnHost() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for marker in homeMarkers where fm.fileExists(atPath: home.appending(path: marker).path) {
            return true
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return path.split(separator: ":").contains { fm.isExecutableFile(atPath: "\($0)/\(binary)") }
    }

    /// Throws only when the base image cannot be built; that failure is not the agent's.
    @discardableResult
    static func provision(_ agent: Agent) throws -> Int32 {
        let artifacts = try CLI.provisionOnce()
        let code = (try? runQuietly(agent, artifacts: artifacts)) ?? 1
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.agents, withIntermediateDirectories: true)
        try? fm.removeItem(at: agent.failureMarker)
        if code == 0 {
            fm.createFile(atPath: agent.provisionMarker.path, contents: nil)
        } else {
            fm.createFile(atPath: agent.failureMarker.path, contents: nil)
            FileHandle.standardError.write(Data(
                "  \(Terminal.dim)see \(agent.setupLog.path) (retried daily)\(Terminal.reset)\n".utf8))
        }
        return code
    }

    /// A throwaway workspace, so install scripts see none of your files.
    private static func runQuietly(_ agent: Agent, artifacts: Artifacts) throws -> Int32 {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let scratch = Paths.run.appending(path: "provision-\(agent.binary)-\(getpid())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var script = agent.installScript
        if let seed = agent.seedScript { script += " && (\(seed))" }
        script += " && save"
        let options = SandboxOptions(hostDir: scratch.path,
                                     command: ["/bin/sh", "-c", script],
                                     networkOn: true, waitForNetwork: true, quiet: true, saveApproved: true)
        let steps = Terminal.Steps()
        steps.start("Provisioning \(agent.name) inside the microVM")
        var code: Int32 = 1
        defer { steps.finish(ok: code == 0) }
        code = try redirectingStdout(to: agent.setupLog) {
            try Sandbox(options: options, artifacts: artifacts, credentials: Credentials()).run()
        }
        return code
    }

    private static func redirectingStdout<T>(to log: URL, _ body: () throws -> T) throws -> T {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logFd = open(log.path, O_WRONLY | O_TRUNC)
        guard logFd >= 0 else { throw SidekernelError.provisioning("cannot open \(log.path)") }
        let saved = dup(STDOUT_FILENO)
        dup2(logFd, STDOUT_FILENO)
        close(logFd)
        defer { dup2(saved, STDOUT_FILENO); close(saved) }
        return try body()
    }

    var provisionMarker: URL { Paths.agents.appending(path: "\(binary).provisioned") }
    var failureMarker: URL { Paths.agents.appending(path: "\(binary).failed") }
    var setupLog: URL { Paths.logs.appending(path: "setup-\(binary).log") }
    var lastFailure: Date? {
        (try? FileManager.default.attributesOfItem(atPath: failureMarker.path))?[.modificationDate] as? Date
    }

    enum Paths {
        static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".sidekernel")
        static let agents = root.appending(path: "agents")
        static let logs = root.appending(path: "logs")
        static let run = root.appending(path: "run")
    }
}
