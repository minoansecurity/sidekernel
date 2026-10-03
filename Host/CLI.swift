import Foundation
import Darwin

@main
public enum CLI {
    static let version = "0.1.4"

    public static func main() {
        if let harness = Harness.invoked(argv0: CommandLine.arguments.first ?? "") {
            exit(runHarness(harness, passthrough: Array(CommandLine.arguments.dropFirst())))
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
            try checkHostDir()
            try Harness.provisionDetected()
            return try launch(command: nil)
        } catch { return fail(error) }
    }

    /// On 127 (command not found), installs the harness and retries once.
    static func runHarness(_ harness: Harness, passthrough: [String]) -> Int32 {
        do {
            try checkHostDir()
            try Harness.provisionDetected([harness])
            var code = try launch(command: harness.launchCommand(passthrough), harness: harness)
            if code == 127 {
                guard try Harness.provision(harness, version: harness.hostVersion()) == 0 else { return 1 }
                code = try launch(command: harness.launchCommand(passthrough), harness: harness)
            }
            return code
        } catch { return fail(error) }
    }

    static func launch(command: [String]?, harness: Harness? = nil) throws -> Int32 {
        var options = SandboxOptions(
            hostDir: FileManager.default.currentDirectoryPath, command: command,
            networkOn: networkOn, waitForNetwork: false, quiet: false)
        options.harness = harness
        return try Sandbox(options: options, artifacts: provisionOnce(),
                           credentials: Credentials()).run()
    }

    /// The current folder becomes /workspace, which the harness may read, edit or delete.
    /// Every new folder gets a casual ask, remembered on yes; ~, secrets and system folders
    /// warn every time. Folders exposing host Codex credentials or SideKernel state are refused.
    static func checkHostDir(_ dir: String = FileManager.default.currentDirectoryPath) throws {
        switch hostDirRisk(dir) {
        case .refuse(let why):
            throw SidekernelError.unsafeDir("not starting here: \(why)\n  cd into a project folder and run it there.")
        case .ask(let why):
            guard !allowedDirs.contains(resolvedPath(dir)) else { return }
            guard isatty(STDIN_FILENO) != 0 else { return }
            guard confirm("\(why) [y/N] ") else { throw SidekernelError.unsafeDir("not started") }
            rememberAllowed(resolvedPath(dir))
        case .warn(let why):
            FileHandle.standardError.write(Data(("\(Terminal.red)⚠ \(why)\(Terminal.reset)\n"
                + "  The sandbox can read, edit or delete everything in it.\n").utf8))
            // Nobody to ask: say it loudly and carry on.
            guard isatty(STDIN_FILENO) != 0 else { return }
            guard confirm("  Start here anyway? [y/N] ") else { throw SidekernelError.unsafeDir("not started") }
        }
    }

    enum HostDirRisk: Equatable { case refuse(String), warn(String), ask(String) }

    static func hostDirRisk(_ dir: String, codexHomes: [URL] = CodexCredentials.protectedHomes) -> HostDirRisk {
        let here = resolvedPath(dir)
        let home = resolvedPath(FileManager.default.homeDirectoryForCurrentUser.path)
        let inside = { (root: String) in here == root || here.hasPrefix(root + "/") }
        let tilde = { (path: String) in path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }

        if here == "/" || home.hasPrefix(here + "/") {
            return .refuse("\(tilde(here)) contains your whole home folder.")
        }
        if inside("\(home)/.sidekernel") {
            return .refuse("\(tilde(here)) is SideKernel's own state.")
        }
        if codexHomes.contains(where: { url in
            let codexHome = url.resolvingSymlinksInPath().path
            return here == codexHome || here.hasPrefix(codexHome + "/")
                || (here != home && codexHome.hasPrefix(here + "/"))
        }) {
            return .refuse("this folder would expose your host Codex credentials.")
        }
        if here == home {
            return .warn("~ is your whole home folder (SideKernel state and Codex credentials stay hidden).")
        }
        // Secrets and the system, at any depth.
        let secret = [".ssh", ".gnupg", ".aws", ".kube", ".docker", "Library"].map { "\(home)/\($0)" }
        let system = ["/System", "/Library", "/usr", "/bin", "/sbin", "/opt",
                      "/private/etc", "/private/var/db", "/private/var/root"]
        if let root = (secret + system).first(where: inside),
           !inside("\(home)/Library/Mobile Documents") {  // iCloud Drive projects are fine
            return .warn("\(tilde(here)) is inside \(tilde(root)).")
        }
        // Full of unrelated files; a project inside them is fine.
        let crowded = ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads", "\(home)/.config",
                       "/Applications", "/Volumes", "/Users/Shared"]
        if crowded.contains(here) {
            return .ask("\(tilde(here)) is not a project folder. Start here anyway?")
        }
        return .ask("You are about to start a sandbox inside \(tilde(here)). Continue?")
    }

    static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func confirm(_ prompt: String) -> Bool {
        // Typed or pasted before the question, so it is not an answer to it.
        tcflush(STDIN_FILENO, TCIFLUSH)
        FileHandle.standardError.write(Data(prompt.utf8))
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// Folders you said yes to, one path per line.
    private static let allowedFile = Harness.Paths.root.appending(path: "allowed-dirs")

    private static var allowedDirs: Set<String> {
        let text = (try? String(contentsOf: allowedFile, encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map(String.init))
    }

    private static func rememberAllowed(_ dir: String) {
        let lines = (allowedDirs.union([dir])).sorted().joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: Harness.Paths.root, withIntermediateDirectories: true)
        try? lines.write(to: allowedFile, atomically: true, encoding: .utf8)
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

    static var commandNames: [String] { ["sidekernel", "sk"] + Harness.table.map(\.argv0) }

    /// argv[0] selects the harness, so every command is a symlink to this binary.
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
            let names = commandNames
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
        let codexLogin = CodexCredentials().hasCredential()
        // Two installs (say ~/.local/bin and Homebrew): the first on PATH wins.
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        let installs = commandNames.flatMap { name in
            dirs.map { "\($0)/\(name)" }.filter { fm.isExecutableFile(atPath: $0) }
        }
        let targets = Set(installs.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent().path
        })
        let missing = commandNames.filter { name in
            !dirs.contains { fm.isExecutableFile(atPath: "\($0)/\(name)") }
        }
        var installStatus = targets.isEmpty ? "no install on PATH; run make install"
            : targets.count == 1 ? "one install on PATH"
            : "installed more than once, the first on PATH wins: \(targets.sorted().joined(separator: ", "))"
        if !missing.isEmpty && !targets.isEmpty {
            installStatus += "; missing commands: \(missing.joined(separator: ", ")) (run sidekernel install)"
        }
        let installsOK = targets.count == 1 && missing.isEmpty

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
        \(line(installsOK, installStatus))
        \(line(true, "Claude login: \(login ? "in Keychain (read-only check)" : "none (/login on the host or inside a sandbox)")"))
        \(line(true, "Codex login: \(codexLogin ? "available on the host (read-only check)" : "none (run codex login on the host)" )"))
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

      sidekernel install    put sk + the harness commands on your PATH
      sidekernel doctor     side-effect-free health report
      sidekernel saved      what `save` kept in your personal layer

    \(Harness.table.map { "  \($0.argv0) [args…]        \($0.name) in this directory's sandbox (args pass through)" }.joined(separator: "\n"))

    SK_NO_NETWORK=1 boots pinned: no internet/LAN.
    \(Onboarding.inferenceAvailability)
    Inside a sandbox: save · sk-drop <host path> · sk-net on|off|status
    """
}

public enum SidekernelError: Error, CustomStringConvertible {
    case provisioning(String), vm(String), agentProtocol(String), timeout(String), unsafeDir(String)

    public var description: String {
        switch self {
        case .provisioning(let m): return m
        case .vm(let m): return m
        case .agentProtocol(let m): return "guest agent protocol: \(m)"
        case .timeout(let m): return "timed out: \(m)"
        case .unsafeDir(let m): return m
        }
    }
}

struct Harness {
    let argv0: String
    let name: String
    let binary: String
    /// Installs the given version in the microVM; nil installs a default when the Mac has none to match.
    let installScript: @Sendable (String?) -> String
    let homeMarkers: [String]
    let seedScript: String?
    var tips: [String] = []

    static let table: [Harness] = [
        Harness(argv0: "sclaude", name: "Claude Code", binary: "claude",
              installScript: { version in
                  let update = "{ apt-get update || { rm -rf /var/lib/apt/lists/* && apt-get update; }; } || true; "
                  guard let version else {
                      return update + "DEBIAN_FRONTEND=noninteractive apt-get install -y claude-code"
                  }
                  // The apt repo keeps past releases. Pick the package build of the Mac's version, e.g. 2.1.177-1.
                  return update
                      + "v=$(apt-cache madison claude-code | awk -v want='\(version)-' 'index($3, want) == 1 { print $3; exit }'); "
                      + "[ -n \"$v\" ] && DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades claude-code=\"$v\""
              },
              homeMarkers: [".claude.json", ".claude"],
              seedScript: "[ -e \"$HOME/.claude.json\" ] || printf '%s' "
                  + "'\(Onboarding.firstRunStateJSON)' > \"$HOME/.claude.json\"",
              tips: [
                  "you can drag and drop host files into Claude Code",
                  "you can paste images into Claude Code with Ctrl+V",
                  "sclaude on the Mac starts Claude Code in a sandbox",
                  "Claude Code uses your host login through the inference proxy",
                  "your host Claude skills and plugins come along",
                  "Claude Code remembers conversations per folder",
              ]),
        Harness(argv0: "scodex", name: "Codex", binary: "codex",
              installScript: { version in
                  "npm install -g @openai/codex@\(version ?? Provisioning.Codex.version)"
              },
              homeMarkers: [".codex"], seedScript: nil, tips: [
                  "you can paste images into Codex with Ctrl+V",
                  "scodex on the Mac starts Codex in a sandbox",
                  "Codex uses your host login through the inference proxy",
                  "Codex history and settings persist separately for each project",
              ]),
    ]

    static func invoked(argv0: String) -> Harness? {
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

    /// Keeps each harness in the microVM at the same version as on the Mac.
    /// After the Mac updates one, the next launch installs that version in the microVM first.
    /// Scoped to `harnesses`: launching `scodex` syncs only Codex, never the other harnesses.
    static func provisionDetected(_ harnesses: [Harness] = table) throws {
        guard CLI.networkOn, canBootVM else { return }
        for harness in harnesses where harness.isOnHost() {
            let version = harness.hostVersion()
            guard harness.needsInstall(matching: version), harness.retryDue(for: version) else { continue }
            try provision(harness, version: version)
        }
    }

    /// Not installed yet, or installed at another version than the Mac's.
    func needsInstall(matching version: String?) -> Bool {
        guard let installed = try? String(contentsOf: provisionMarker, encoding: .utf8) else { return true }
        guard let version else { return false }
        return installed != version
    }

    /// A failed install is retried daily, or right away once the Mac has another version.
    func retryDue(for version: String?) -> Bool {
        guard let lastFailure else { return true }
        let failedVersion = (try? String(contentsOf: failureMarker, encoding: .utf8)) ?? ""
        if failedVersion != (version ?? "") { return true }
        return Self.retryDue(after: lastFailure)
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
        return hostBinary() != nil
    }

    /// The harness on the Mac's PATH, or nil when it is not installed there.
    func hostBinary() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    // MARK: - Host version

    /// The version on the Mac, from `<binary> --version`.
    /// Remembered per installed file, so the harness runs again only after it changes.
    func hostVersion() -> String? {
        guard let tool = hostBinary() else { return nil }
        // npm resets file times on install, so a reinstall shows as a new inode and change time.
        let resolved = tool.resolvingSymlinksInPath().path
        var info = stat()
        guard stat(resolved, &info) == 0 else { return nil }
        let key = "\(resolved) \(info.st_ino) \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"

        if let cached = try? String(contentsOf: hostVersionCache, encoding: .utf8) {
            let lines = cached.split(separator: "\n").map(String.init)
            if lines.count == 2, lines[0] == key, let version = Self.parseVersion(lines[1]) {
                return version
            }
        }
        guard let output = Self.output(of: tool, ["--version"]),
              let version = Self.parseVersion(output) else { return nil }
        try? FileManager.default.createDirectory(at: Paths.provisioning, withIntermediateDirectories: true)
        try? "\(key)\n\(version)\n".write(to: hostVersionCache, atomically: true, encoding: .utf8)
        return version
    }

    /// "codex-cli 0.160.0" or "2.1.177 (Claude Code)" gives the version.
    /// Only digits, letters, ".", "-" and "+" pass, since the version goes into the install script.
    static func parseVersion(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+")
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let first = word.first, first.isASCII, first.isNumber, word.contains("."),
                  word.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { continue }
            return String(word)
        }
        return nil
    }

    /// The standard output of a quick host command, or nil if it fails or takes over 5 seconds.
    private static func output(of tool: URL, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = tool
        p.arguments = arguments
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timeout = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        // Drain to EOF, then wait: reading first cannot deadlock on a full pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timeout.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Throws only when the base image cannot be built; that failure is not the harness's.
    /// The markers hold the version: what is installed, or what failed to install.
    @discardableResult
    static func provision(_ harness: Harness, version: String?) throws -> Int32 {
        let artifacts = try CLI.provisionOnce()
        let code = (try? runQuietly(harness, version: version, artifacts: artifacts)) ?? 1
        let fm = FileManager.default
        let contents = Data((version ?? "").utf8)
        try? fm.createDirectory(at: Paths.provisioning, withIntermediateDirectories: true)
        try? fm.removeItem(at: harness.failureMarker)
        if code == 0 {
            fm.createFile(atPath: harness.provisionMarker.path, contents: contents)
        } else {
            fm.createFile(atPath: harness.failureMarker.path, contents: contents)
            FileHandle.standardError.write(Data(
                "  \(Terminal.dim)see \(harness.setupLog.path) (retried daily)\(Terminal.reset)\n".utf8))
        }
        return code
    }

    /// A throwaway workspace, so install scripts see none of your files.
    private static func runQuietly(_ harness: Harness, version: String?, artifacts: Artifacts) throws -> Int32 {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let scratch = Paths.run.appending(path: "provision-\(harness.binary)-\(getpid())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var script = harness.installScript(version)
        if let seed = harness.seedScript { script += " && (\(seed))" }
        script += " && save"
        let options = SandboxOptions(hostDir: scratch.path,
                                     command: ["/bin/sh", "-c", script],
                                     networkOn: true, waitForNetwork: true, quiet: true, saveApproved: true)
        let steps = Terminal.Steps()
        if let version {
            steps.start("Installing \(harness.name) \(version) inside the microVM to match your Mac")
        } else {
            steps.start("Provisioning \(harness.name) inside the microVM")
        }
        var code: Int32 = 1
        defer { steps.finish(ok: code == 0) }
        code = try redirectingStdout(to: harness.setupLog) {
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

    var provisionMarker: URL { Paths.provisioning.appending(path: "\(binary).provisioned") }
    var failureMarker: URL { Paths.provisioning.appending(path: "\(binary).failed") }
    var setupLog: URL { Paths.logs.appending(path: "setup-\(binary).log") }
    var hostVersionCache: URL { Paths.provisioning.appending(path: "\(binary).host-version") }
    var lastFailure: Date? {
        (try? FileManager.default.attributesOfItem(atPath: failureMarker.path))?[.modificationDate] as? Date
    }

    enum Paths {
        static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".sidekernel")
        // Keep the existing on-disk directory so provisioning markers survive upgrades.
        static let provisioning = root.appending(path: "agents")
        static let logs = root.appending(path: "logs")
        static let run = root.appending(path: "run")
    }
}
