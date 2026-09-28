import CryptoKit
import Foundation
import Darwin

public struct Sandbox {
    private let options: SandboxOptions
    private let artifacts: Artifacts
    private let credentials: Credentials

    public init(options: SandboxOptions, artifacts: Artifacts, credentials: Credentials) {
        (self.options, self.artifacts, self.credentials) = (options, artifacts, credentials)
    }

    public func run() throws -> Int32 {
        let fm = FileManager.default
        let runID = Self.randomRunID()
        // An install run gets throwaway state, so it leaves no project folder behind.
        let projectDir = try options.quiet
            ? fm.temporaryDirectory.appending(path: "sidekernel-project-\(runID)")
            : ProjectIdentity.stateDir(for: options.hostDir)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { if options.quiet { try? fm.removeItem(at: projectDir) } }
        let seedDir = fm.temporaryDirectory.appending(path: "sidekernel-seed-\(runID)")
        try Onboarding.buildSeed(at: seedDir)
        defer { try? fm.removeItem(at: seedDir) }

        let store = PersonalStore(directory: fm.homeDirectoryForCurrentUser.appending(path: ".sidekernel"))
        let staging = try store.makeStagingClone(runID: runID)
        defer { try? fm.removeItem(at: staging) }

        let vm = MicroVM(spec: VMSpec(
            kernelURL: artifacts.kernel, initramfsURL: artifacts.initramfs,
            baseImage: artifacts.baseImage, baseReadOnly: true,
            personalImage: artifacts.personalImage, stagingImage: staging,
            workspaceDir: options.hostDir, projectDir: projectDir, seedDir: seedDir, overlayBoot: true,
            waitForNetwork: options.waitForNetwork, networkOn: options.networkOn,
            cpuCount: 2, memoryMB: 10240))
        try vm.start()
        defer { try? vm.stop() }

        let interactive = !options.quiet && isatty(STDIN_FILENO) != 0
        // No stdin pump, so the clipboard window never opens.
        let grant = interactive ? ClipboardGrant() : nil
        let session = Session(vm: vm, grant: grant)
        let notify: @Sendable (UInt16, PortForwarder.Outcome) -> Void = { port, outcome in
            switch outcome {
            case .forwarded:
                Terminal.notice("🌐 localhost:\(port) · sandbox:\(port)")
            case .lowPort:
                Terminal.notice("🌐 sandbox:\(port) not forwarded: ports below "
                    + "\(PortForwarder.lowestForwarded) belong to system services. Use a higher port.")
            case .inUse:
                Terminal.notice("🌐 sandbox:\(port) not forwarded: port \(port) is already in use on your Mac. "
                    + "Stop the Mac's server or use another port.")
            case .failed(let reason):
                Terminal.notice("🌐 sandbox:\(port) not forwarded: \(reason)")
            }
        }
        let onOpen: (@Sendable (UInt16, PortForwarder.Outcome) -> Void)? = options.quiet ? nil : notify
        let forwarder = PortForwarder(vm: vm, onOpen: onOpen)
        defer { forwarder.stop() }

        let services = Services(
            vm: vm, session: session, forwarder: forwarder,
            proxy: Proxy(credentials: credentials), credentials: credentials,
            approval: HostApproval(), grant: grant,
            store: store, staging: staging,
            personalAttached: artifacts.personalImage != nil,
            networkOn: options.networkOn, hostDir: options.hostDir, projectDir: projectDir,
            quiet: options.quiet, saveApproved: options.saveApproved)
        try vm.listenService { fd in services.accept(fd) }

        if !options.quiet {
            FileHandle.standardError.write(Data(
                Terminal.header(hostDir: options.hostDir).utf8))
        }
        let controlFd = try vm.dialControl(timeout: 15)
        // An install run never touches the Keychain.
        let routeAnthropic = !options.quiet
        let anthropicAuthenticated = !options.quiet && credentials.hasAnthropicCredential()
        let env = Self.shellEnvironment(routeAnthropic: routeAnthropic,
                                        anthropicAuthenticated: anthropicAuthenticated,
                                        hostDir: options.hostDir,
                                        hostEnv: ProcessInfo.processInfo.environment)
        // A shell comes up before the skills and plugins are copied; a command waits for them.
        let command = options.command.map { [Self.seedCommand] + $0 }
            ?? [Self.seedCommand, "--lazy"] + Self.interactiveShell
        return try session.run(controlFd: controlFd,
                               command: command,
                               workDir: "/workspace", env: env,
                               networkOn: options.networkOn, tty: interactive)
    }

    /// Merges the seed into the agent config, then execs the command.
    static let seedCommand = "/run/sidekernel/libexec/seed"

    /// Our rc, which sources a saved `/root/.bashrc` back.
    static let interactiveShell =
        ["/bin/sh", "-c", "ENV=/run/sidekernel/bashrc exec /bin/bash --rcfile /run/sidekernel/bashrc -i"]

    static func randomRunID() -> String {
        "sk-" + String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    // MARK: - Guest environment

    static func shellEnvironment(routeAnthropic: Bool, anthropicAuthenticated: Bool,
                                 hostDir: String, hostEnv: [String: String]) -> [String] {
        var env = [
            "TERM=xterm-256color", "LANG=C.UTF-8", "HOME=/root",
            "HISTSIZE=1000", "HISTFILESIZE=2000", "HISTCONTROL=ignoredups:erasedups",
            "LS_COLORS=di=38;2;0;190;218:ln=38;2;160;100;210:ex=38;2;72;209;176",
            "CLAUDE_CONFIG_DIR=\(Contract.guestConfigDir)",
            // The fullscreen renderer scrolls on mouse events, which the output filter strips.
            "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1",
            // Claude Code's /copy runs wl-copy only when this is set; otherwise it falls back to OSC 52,
            // which the output filter strips. Nothing listens on it; wl-copy is our clip script.
            "WAYLAND_DISPLAY=sidekernel",
            "SK_SANDBOX=1",
            "SIDEKERNEL_PROJECT=\(Terminal.sanitizedProjectName(hostDir))",
        ]
        if hostEnv["NO_COLOR"] != nil { env.append("NO_COLOR=1") }
        let zone = TimeZone.current.identifier
        if zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/_+-".contains($0)) }) {
            env.append("TZ=\(zone)")
        }
        if routeAnthropic {
            env.append("ANTHROPIC_BASE_URL=http://127.0.0.1:\(Contract.relayPort)")
            // The placeholder also tells the CLI it is logged in; without host auth it would hide /login.
            if anthropicAuthenticated {
                env.append("ANTHROPIC_API_KEY=\(Contract.placeholderKey)")
            }
        }
        return env
    }
}

public struct SandboxOptions {
    public var hostDir: String
    public var command: [String]?
    public var networkOn: Bool
    public var waitForNetwork: Bool
    public var quiet: Bool
    /// The host's own install run: its one `save` needs no dialog, since you started it by running sk.
    public var saveApproved: Bool
    public init(hostDir: String, command: [String]?, networkOn: Bool,
                waitForNetwork: Bool, quiet: Bool, saveApproved: Bool = false) {
        (self.hostDir, self.command) = (hostDir, command)
        (self.networkOn, self.waitForNetwork, self.quiet) = (networkOn, waitForNetwork, quiet)
        self.saveApproved = saveApproved
    }
}

/// One thread per connection, so approvals never queue.
private final class Services: @unchecked Sendable {
    private let vm: MicroVM
    private let session: Session
    private let forwarder: PortForwarder
    private let proxy: Proxy
    private let credentials: Credentials
    private let approval: HostApproval
    private let grant: ClipboardGrant?
    private let store: PersonalStore
    private let staging: URL
    private let personalAttached: Bool
    private let hostDir: String
    private let projectDir: URL
    private let quiet: Bool
    /// One save only, so a second one from the same run still asks.
    private var saveApproved: Bool
    private let saveLock = NSLock()
    /// The host's view, never the guest's claim.
    private var networkOn: Bool
    private let netLock = NSLock()

    init(vm: MicroVM, session: Session, forwarder: PortForwarder, proxy: Proxy,
         credentials: Credentials, approval: HostApproval, grant: ClipboardGrant?,
         store: PersonalStore, staging: URL, personalAttached: Bool,
         networkOn: Bool, hostDir: String, projectDir: URL, quiet: Bool, saveApproved: Bool) {
        (self.vm, self.session, self.forwarder, self.proxy) = (vm, session, forwarder, proxy)
        (self.credentials, self.approval, self.grant) = (credentials, approval, grant)
        (self.store, self.staging, self.personalAttached) = (store, staging, personalAttached)
        (self.networkOn, self.hostDir, self.projectDir, self.quiet) = (networkOn, hostDir, projectDir, quiet)
        self.saveApproved = saveApproved
    }

    private func takeSaveApproval() -> Bool {
        saveLock.lock()
        defer { saveLock.unlock() }
        let approved = saveApproved
        saveApproved = false
        return approved
    }

    func accept(_ fd: Int32) {
        Thread { self.dispatch(fd) }.start()
    }

    private func dispatch(_ fd: Int32) {
        FDIO.setReadTimeout(fd, seconds: 10)
        guard let hello = try? FDIO.readFrame(fd, cap: Contract.maxControlFrame) else {
            close(fd)
            return
        }
        switch hello {
        case .helloStdio(let which, let nonce):
            FDIO.setReadTimeout(fd, seconds: 0)
            _ = session.claimStdio(which: which, nonce: nonce, fd: fd)
        case .helloPortEvents:
            FDIO.setReadTimeout(fd, seconds: 0)
            forwarder.handleEvents(fd)
        case .helloProxy:
            proxy.handle(fd)
        case .adopt(let blob):
            reply(fd, adopt(blob))
        case .ctl(let verb, let payload):
            reply(fd, control(verb, payload, on: fd))
        default:
            close(fd)
        }
    }

    private func reply(_ fd: Int32, _ frame: Frame) {
        _ = FDIO.writeFrame(fd, frame)
        close(fd)
    }

    // MARK: - Verbs

    private func adopt(_ blob: [UInt8]) -> Frame {
        guard !quiet else { return err("adoption unavailable in this run") }
        // Validate first, so junk never raises a dialog.
        if let rejection = Credentials.adoptionRejection(for: blob) { return rejection }
        guard approval.ask(
            "SideKernel: a /login inside the sandbox in\\n\(HostApproval.appleScriptEscape(hostDir))\\n"
                + "wants to save its Claude credential to your Mac's Keychain. Allow?")
        else { return Frame.ctlReply(status: .deny, message: "denied on the host", payload: []) }
        return credentials.adopt(blob: blob)
    }

    /// A drop streams on `fd` before its last reply.
    private func control(_ verb: CtlVerb, _ payload: [UInt8], on fd: Int32) -> Frame {
        switch verb {
        case .save:
            guard payload.count == 1, payload[0] <= 1 else { return err("malformed save request") }
            guard takeSaveApproval() || approval.ask(
                "SideKernel: the sandbox in\\n\(HostApproval.appleScriptEscape(hostDir))\\n"
                    + "wants to save its changes to your personal layer.\\n\\n"
                    + "Every future sandbox, in every project, will start with them. "
                    + "The sandbox listed the files in your terminal. Allow?")
            else { return Frame.ctlReply(status: .deny, message: "denied on the host", payload: []) }
            let outcome = store.publish(staging: staging, personalIncluded: payload[0] == 1,
                                        personalAttached: personalAttached)
            if case .ctlReply(.ok, _, _) = outcome {
                store.ingestListing(fromProjectState: projectDir)
            }
            return outcome
        case .clip:
            return Clipboard.service(grant: grant)
        case .copy:
            return Clipboard.service(copy: payload, approval: approval)
        case .drop:
            guard let raw = String(bytes: payload, encoding: .utf8) else {
                return err("malformed drop request")
            }
            // /workspace is already mounted, and is the one host dir the guest can rewrite.
            let mounted = URL(fileURLWithPath: hostDir).resolvingSymlinksInPath().path
            return DropIn.service(rawPath: raw, mounted: mounted, approval: approval, to: fd)
        case .net:
            switch String(bytes: payload, encoding: .utf8) {
            case "on": return setNetwork(true)
            case "off": return setNetwork(false)
            default: return err("invalid request")
            }
        }
    }

    private func setNetwork(_ want: Bool) -> Frame {
        netLock.lock()
        defer { netLock.unlock() }
        if want == networkOn { return Frame.ctlReply(status: .ok, message: "", payload: []) }
        if want, !approval.ask(
            "SideKernel: turn the network ON for the sandbox in\\n\(HostApproval.appleScriptEscape(hostDir))?\\n\\n"
                + "This opens FULL internet and local-network access for that sandbox until you "
                + "run sk-net off. Right now only the Claude API is reachable.") {
            return Frame.ctlReply(status: .deny, message: "denied on the host", payload: [])
        }
        // Posture is updated before the reply, so a guest that saw ok never acts on a stale one.
        guard vm.setNetwork(on: want) else { return err("network unavailable") }
        networkOn = want
        Terminal.notice(want ? "🌐 network on" : "🔌 network off")
        Terminal.updateStatus(networkOn: want)
        return Frame.ctlReply(status: .ok, message: "", payload: [])
    }

    private func err(_ message: String) -> Frame {
        .ctlReply(status: .err, message: message, payload: [])
    }
}

/// This boot's read-only seed: user-authored Claude config, never history or secrets.
/// The host writes only here, so no guest-planted symlink can redirect a host write.
enum Onboarding {
    static func buildSeed(at seedDir: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: seedDir)
        let claudeSeed = seedDir.appending(path: "claude")
        try fm.createDirectory(at: claudeSeed, withIntermediateDirectories: true)
        try sandboxGuidance.write(to: claudeSeed.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        // Applied only where the guest has none yet.
        try firstRunStateJSON.write(to: claudeSeed.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        let hostClaudeDir = hostClaudeConfigDir()
        copyHostConfigs(from: hostClaudeDir, into: claudeSeed)
        try fingerprint(of: hostClaudeDir).write(to: claudeSeed.appending(path: "seed.fp"),
                                                 atomically: true, encoding: .utf8)
    }

    /// Lets the guest `seed` script skip re-copying over virtiofs when nothing changed. Metadata only, so it is fast.
    static func fingerprint(of hostClaudeDir: URL) -> String {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var hasher = SHA256()
        for sub in copiedDirs {
            let src = hostClaudeDir.appending(path: sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue,
                  let walker = fm.enumerator(at: src, includingPropertiesForKeys: keys) else { continue }
            var lines = [src.path]
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let link = values?.isSymbolicLink == true
                    ? (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "" : ""
                lines.append([url.path, values?.isDirectory == true ? "d" : "f",
                              String(values?.fileSize ?? -1),
                              String(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0),
                              link].joined(separator: "\t"))
            }
            for line in lines.sorted() {
                hasher.update(data: Data(line.utf8))
                hasher.update(data: Data([0]))   // an unambiguous boundary between entries
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() + "\n"
    }

    static let copiedDirs = ["skills", "commands", "agents", "plugins"]

    static func hostClaudeConfigDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    static func copyHostConfigs(from hostClaudeDir: URL, into claudeSeed: URL) {
        let fm = FileManager.default
        for sub in copiedDirs {
            let src = hostClaudeDir.appending(path: sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { continue }
            try? fm.copyItem(at: src, to: claudeSeed.appending(path: sub))
        }
        repointMarketplaces(in: claudeSeed)
        liftPluginEnablement(hostClaudeDir: hostClaudeDir, into: claudeSeed)
    }

    /// Host paths become guest paths; entries that never crossed are dropped.
    static func repointMarketplaces(in claudeSeed: URL) {
        let registry = claudeSeed.appending(path: "plugins/known_marketplaces.json")
        guard let raw = try? Data(contentsOf: registry),
              let top = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return }
        let marketplaces = claudeSeed.appending(path: "plugins/marketplaces")
        var out: [String: Any] = [:]
        for (name, value) in top {
            guard var entry = value as? [String: Any],
                  let location = entry["installLocation"] as? String else { continue }
            let dirName = URL(fileURLWithPath: location).lastPathComponent
            guard FileManager.default.fileExists(atPath: marketplaces.appending(path: dirName).path)
            else { continue }
            entry["installLocation"] = "\(Contract.guestConfigDir)/plugins/marketplaces/\(dirName)"
            out[name] = entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out) else { return }
        try? data.write(to: registry, options: .atomic)
    }

    /// Only `enabledPlugins` crosses; hooks, env and key helpers stay on the host.
    static func liftPluginEnablement(hostClaudeDir: URL, into claudeSeed: URL) {
        guard let raw = try? Data(contentsOf: hostClaudeDir.appending(path: "settings.json")),
              let top = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let enabled = top["enabledPlugins"],
              let data = try? JSONSerialization.data(withJSONObject: enabled, options: .fragmentsAllowed)
        else { return }
        try? data.write(to: claudeSeed.appending(path: "enabled-plugins.json"), options: .atomic)
    }

    /// Pre-answers the onboarding wizard, the workspace trust dialog, and the custom-key gate.
    static var firstRunStateJSON: String {
        let approvedKey = String(Contract.placeholderKey.suffix(20))
        return #"{"hasCompletedOnboarding":true,"theme":"dark","customApiKeyResponses":{"approved":["\#(approvedKey)"],"rejected":[]},"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}"#
    }

    /// The guest's CLAUDE.md.
    static let sandboxGuidance = """
    You are inside a SideKernel sandbox: a full Linux system whose only window onto the macOS host is /workspace (the current project). Everything else on the Mac (e.g. /Users/..., ~/Downloads/...) is invisible from here until it is handed in.

    RULE: when the user references a macOS host path that is not under /workspace and not already in this Linux filesystem, your FIRST action is to run sk-drop on it. Do not explain that you can't see it, do not say it's out of reach, do not ask permission first, do not offer alternatives. Just run sk-drop and let the host prompt decide. Acting is the correct move every time. Approval is the user's job, not yours to pre-empt.

    - File or folder, same command: sk-drop /absolute/macos/host/path, always the absolute host path. You do not need to know which it is first.
    - The SideKernel hypervisor asks the user on the host to Allow or Deny; nothing crosses without that explicit approval and you cannot grant it yourself.
    - On Allow it lands at /root/.sk-drops/<basename> (guest-only, ephemeral), a file as that file, a folder as a directory of that name, and sk-drop prints the path. Read it from there. On Deny, do not retry.

    The failure mode to avoid: seeing a macOS path, running `ls`, getting "No such file", and then narrating why it's inaccessible. That is wrong. A macOS path means sk-drop, immediately.

    Network kill switch: `sk-net status` shows this sandbox's internet posture, `sk-net off` cuts all internet/LAN access instantly (Claude API calls keep working), and `sk-net on` asks the human on the host. Approval happens there and you cannot grant it yourself. If network commands (curl, apt, pip, git fetch) fail or hang while the network is off, that is the kill switch, not a bug: say so, and run `sk-net on` only when the user wants the network back, once, then let the host prompt decide. Never retry after a deny.
    """
}
