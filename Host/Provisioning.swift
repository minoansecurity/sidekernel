import CryptoKit
import Foundation
import Darwin

public struct Provisioning {

    // MARK: - Pinned upstreams

    /// Kata's newest release still shipping `.tar.xz`; macOS tar has no zstd.
    enum Kernel {
        static let version = "3.20.0"
        static let tarballURL = URL(string:
            "https://github.com/kata-containers/kata-containers/releases/download/\(version)/kata-static-\(version)-arm64.tar.xz")!
        static let tarballSHA256 = "e190d41ce15943e5aaf8c54e3c6538f6b556f74c9ace516a67c018c863e78d35"
        static let megabytes = 295
    }

    enum Base {
        static let version = "26.04.1"
        static let codename = "resolute"
        static let rootfsURL = URL(string:
            "https://cdimage.ubuntu.com/ubuntu-base/releases/\(codename)/release/ubuntu-base-\(version)-base-arm64.tar.gz")!
        static let rootfsSHA256 = "5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd"
        static let megabytes = 35
        /// Every entry is guest attack surface; iproute2 and any DHCP client are deliberately absent.
        static let aptInstall = [
            "ca-certificates", "curl", "git", "jq", "ripgrep",
            "python3", "python3-pip", "python3-venv", "nodejs", "npm", "procps",
            "nano", "vim-tiny", "less", "iputils-ping", "tzdata",
        ]
    }

    /// The apt repo key is checked against this fingerprint before it is trusted.
    enum Claude {
        static let aptRepoURL = "https://downloads.claude.ai/claude-code/apt/latest"
        static let aptSuite = "latest"
        static let aptComponent = "main"
        static let gpgKeyURL = URL(string: "https://downloads.claude.ai/keys/claude-code.asc")!
        static let gpgKeyFingerprint = "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
    }

    enum Codex {
        static let version = "0.159.2"
    }

    private let root: URL
    private var images: URL { root.appending(path: "images") }
    private var logs: URL { root.appending(path: "logs") }
    private var baseImage: URL { images.appending(path: "sidekernel-base.img") }

    public init() {
        root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".sidekernel")
    }

    static func stagingTemplate(root: URL) -> URL {
        root.appending(path: "images/staging-template.img")
    }

    public func ensureAll(steps: Terminal.Steps) throws -> Artifacts {
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        return try Self.locked(root.appending(path: ".provision.lock"), whileWaiting: {
            steps.start("Waiting for another sidekernel to finish provisioning the microVM")
        }) { () throws -> Artifacts in
            steps.finish()
            try checkStateVersion()
            if !FileManager.default.fileExists(atPath: baseImage.path) {
                steps.note("First run: building the root filesystem (a few minutes).")
            }
            let kernel = try ensureKernel(steps: steps)
            let initramfs = try ensureTinyInitramfs()
            let (base, template) = try ensureBaseAndTemplate(kernel: kernel, steps: steps)
            let personal = root.appending(path: "personal/overlay.img")
            return Artifacts(
                kernel: kernel, initramfs: initramfs, baseImage: base, stagingTemplate: template,
                personalImage: FileManager.default.fileExists(atPath: personal.path) ? personal : nil)
        }
    }

    /// Layout version of ~/.sidekernel. Bump it, with a migration here, when stored state changes shape.
    static let stateVersion = 1

    private func checkStateVersion() throws {
        let file = root.appending(path: "state-version")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            try "\(Self.stateVersion)\n".write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let found = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if found > Self.stateVersion {
            throw SidekernelError.provisioning("~/.sidekernel was set up by a newer SideKernel. Update with: brew upgrade sidekernel")
        }
    }

    /// Hashed against the pin before the rename; a cached copy is re-hashed too.
    public static func fetchVerified(from url: URL, sha256 want: String, to destination: URL,
                                     downloading: ((URL) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try locked(destination.appendingPathExtension("lock")) {
            if FileManager.default.fileExists(atPath: destination.path) {
                if (try? sha256(of: destination)) == want { return }
                try? FileManager.default.removeItem(at: destination)
            }
            let part = destination.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: part)
            downloading?(part)
            try runTool("/usr/bin/curl",
                        ["-fL", "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
                         "--max-redirs", "5", "--retry", "3", "-sS",
                         "-o", part.path, url.absoluteString],
                        fail: "download failed: \(url.lastPathComponent)")
            let got = try sha256(of: part)
            guard got == want else {
                try? FileManager.default.removeItem(at: part)
                throw SidekernelError.provisioning(
                    "\(url.lastPathComponent) sha256 mismatch: expected \(want), got \(got)")
            }
            guard rename(part.path, destination.path) == 0 else {
                try? FileManager.default.removeItem(at: part)
                throw SidekernelError.provisioning("could not publish \(destination.lastPathComponent)")
            }
        }
    }

    private func ensureKernel(steps: Terminal.Steps) throws -> URL {
        let fm = FileManager.default
        let cached = root.appending(path: "kernel/vmlinux")
        let sidecar = root.appending(path: "kernel/vmlinux.sha256")
        // "<tarball pin> <vmlinux sha256>": a new pin refetches even when the cached copy is intact.
        if fm.fileExists(atPath: cached.path),
           let have = try? String(contentsOf: sidecar, encoding: .utf8),
           let sha = try? Self.sha256(of: cached),
           have.trimmingCharacters(in: .whitespacesAndNewlines) == "\(Kernel.tarballSHA256) \(sha)" {
            return cached
        }
        let work = root.appending(path: "kernel/.fetch")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let tarball = work.appending(path: "kata-static.tar.xz")
        try Self.fetchVerified(from: Kernel.tarballURL, sha256: Kernel.tarballSHA256, to: tarball) { part in
            steps.start("Fetching the microVM kernel", detail: { Self.downloaded(part, of: Kernel.megabytes) })
        }
        steps.start("Preparing the microVM kernel")
        try Self.runTool("/usr/bin/tar",
                         ["-xJf", tarball.path, "-C", work.path, "opt/kata/share/kata-containers/"],
                         fail: "kernel extraction failed")
        let vmlinux = try Self.resolveVmlinux(in: work.appending(path: "opt/kata/share/kata-containers"))
        let staged = root.appending(path: "kernel/.vmlinux.new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: vmlinux, to: staged)
        try "\(Kernel.tarballSHA256) \(try Self.sha256(of: staged))".write(to: sidecar, atomically: true, encoding: .utf8)
        guard rename(staged.path, cached.path) == 0 else {
            try? fm.removeItem(at: staged)
            throw SidekernelError.provisioning("could not publish vmlinux")
        }
        return cached
    }

    /// "41 / 295 MB" while curl writes `part`.
    private static func downloaded(_ part: URL, of megabytes: Int) -> String? {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int
        else { return nil }
        return "\((bytes + 500_000) / 1_000_000) / \(megabytes) MB"
    }

    private static func resolveVmlinux(in dir: URL) throws -> URL {
        let fm = FileManager.default
        let container = dir.appending(path: "vmlinux.container")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: container.path) {
            let real = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : dir.appending(path: dest)
            if fm.fileExists(atPath: real.path) { return real }
        }
        if fm.fileExists(atPath: container.path) { return container }
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if let name = entries.first(where: { $0.hasPrefix("vmlinux-") && !$0.contains("virtiofs") }) {
            return dir.appending(path: name)
        }
        throw SidekernelError.provisioning("no vmlinux found in the Kata tarball")
    }

    // MARK: - Initramfs

    private func ensureTinyInitramfs() throws -> URL {
        let out = images.appending(path: "initramfs-tiny.gz")
        let scripts = try Self.guestTools.map { try Self.bundledResource($0.0) }
        guard try isStale(out, inputs: scripts) else { return out }
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        try installAgent(into: stage)
        try installGuestTools(into: stage)
        try packInitramfs(stage: stage, to: out)
        return out
    }

    private func ensureBuilderInitramfs(ubuntu: URL) throws -> URL {
        let out = images.appending(path: "initramfs-builder.gz")
        guard try isStale(out, inputs: [ubuntu]) else { return out }
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        try Self.runTool("/usr/bin/tar", ["-xpf", ubuntu.path, "-C", stage.path],
                         fail: "ubuntu-base extraction failed")
        try installAgent(into: stage)
        try packInitramfs(stage: stage, to: out)
        return out
    }

    private func isStale(_ cached: URL, inputs: [URL]) throws -> Bool {
        guard let cachedDate = Self.mtime(cached) else { return true }
        var sources = inputs
        sources.append(try Self.bundledResource("sk-agent"))
        return sources.contains { Self.mtime($0).map { $0 > cachedDate } ?? true }
    }

    private func makeStage() throws -> URL {
        let stage = images.appending(path: ".stage-\(UUID().uuidString.prefix(8))/root")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for dir in ["sbin", "base", "over", "merged", "personal", "workspace", "staging",
                    "proc", "sys", "dev", "tmp", "run", "mnt"] {
            try FileManager.default.createDirectory(
                at: stage.appending(path: dir), withIntermediateDirectories: true)
        }
        return stage
    }

    private func installAgent(into stage: URL) throws {
        let dst = stage.appending(path: "sbin/sk-agent")
        try FileManager.default.copyItem(at: try Self.bundledResource("sk-agent"), to: dst)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
    }

    /// The guest scripts ride with sk-agent, not in the base image, so editing one never rebuilds it.
    /// PID 1 moves this tree to /run/sidekernel; only bin/ is on PATH.
    private static let guestTools = [("save", "bin"), ("sk-drop", "bin"), ("sk-net", "bin"),
                                     ("ramblinwreck", "bin"), ("clip", "libexec"), ("seed", "libexec"),
                                     ("codex", "bin"), ("bashrc", "")]
    private static let guestAliases = ["fightsong": "ramblinwreck", "xclip": "../libexec/clip",
                                       "wl-paste": "../libexec/clip", "wl-copy": "../libexec/clip",
                                       "pbcopy": "../libexec/clip"]

    private func installGuestTools(into stage: URL) throws {
        let fm = FileManager.default
        let tools = stage.appending(path: "sidekernel")
        for dir in ["bin", "libexec"] {
            try fm.createDirectory(at: tools.appending(path: dir), withIntermediateDirectories: true)
        }
        for (script, dir) in Self.guestTools {
            let dst = dir.isEmpty ? tools.appending(path: script) : tools.appending(path: dir).appending(path: script)
            try fm.copyItem(at: try Self.bundledResource(script), to: dst)
            try fm.setAttributes([.posixPermissions: dir.isEmpty ? 0o644 : 0o755], ofItemAtPath: dst.path)
        }
        for (alias, target) in Self.guestAliases {
            try fm.createSymbolicLink(atPath: tools.appending(path: "bin").appending(path: alias).path,
                                      withDestinationPath: target)
        }
    }

    /// `pipefail`, so a truncated archive is never published.
    private func packInitramfs(stage: URL, to out: URL) throws {
        let fm = FileManager.default
        let staging = out.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        fm.createFile(atPath: staging.path, contents: nil)
        let handle = try FileHandle(forWritingTo: staging)
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/bin/bash")
        pack.currentDirectoryURL = stage   // via the API, so a quoted host path cannot break the command
        pack.arguments = ["-c", "set -o pipefail; find . -print | cpio -o -H newc 2>/dev/null | gzip -1"]
        pack.standardOutput = handle
        try pack.run()
        pack.waitUntilExit()
        try? handle.close()
        guard pack.terminationStatus == 0, rename(staging.path, out.path) == 0 else {
            try? fm.removeItem(at: staging)
            throw SidekernelError.provisioning("initramfs pack failed (exit \(pack.terminationStatus))")
        }
    }

    // MARK: - Base image and staging template

    /// Fingerprint-stamped, so changed assets force a rebuild.
    private func ensureBaseAndTemplate(kernel: URL, steps: Terminal.Steps) throws -> (URL, URL) {
        let fm = FileManager.default
        let base = baseImage
        let template = Self.stagingTemplate(root: root)
        let stamp = base.appendingPathExtension("fp")
        let fingerprint = try assetFingerprint()
        if fm.fileExists(atPath: base.path), fm.fileExists(atPath: template.path),
           (try? String(contentsOf: stamp, encoding: .utf8)) == fingerprint {
            return (base, template)
        }
        if fm.fileExists(atPath: base.path) {
            steps.note("Rebuilding the root filesystem after an update (that will take a few minutes).")
        }
        try? fm.removeItem(at: stamp)   // invalid until the new artifacts land

        let ubuntu = images.appending(path: "ubuntu-base.tar.gz")
        try Self.fetchVerified(from: Base.rootfsURL, sha256: Base.rootfsSHA256, to: ubuntu) { part in
            steps.start("Fetching the Ubuntu \(Base.version) guest image", detail: { Self.downloaded(part, of: Base.megabytes) })
        }
        steps.start("Booting an isolated build microVM")
        let builderInitramfs = try ensureBuilderInitramfs(ubuntu: ubuntu)
        let key = images.appending(path: "claude-code.asc")
        // Always refetched: the trust anchor is the in-builder fingerprint check, not this file.
        try? fm.removeItem(at: key)
        try Self.runTool("/usr/bin/curl",
                         ["-fL", "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
                          "--max-redirs", "5", "--retry", "3", "-sS", "-o", key.path,
                          Claude.gpgKeyURL.absoluteString],
                         fail: "claude key download failed")

        let baseStaging = base.appendingPathExtension("new")
        let templateStaging = template.appendingPathExtension("new")
        try makeSparseFile(at: baseStaging, gigabytes: 8)
        try runBuilder(
            name: "base-build", kernel: kernel, initramfs: builderInitramfs, disk: baseStaging,
            script: Self.baseBuildScript(ubuntuTar: "ubuntu-base.tar.gz",
                                         templateName: templateStaging.lastPathComponent,
                                         sentinel: ".sk-base-ok"),
            sentinel: ".sk-base-ok", steps: steps)
        guard rename(templateStaging.path, template.path) == 0,
              rename(baseStaging.path, base.path) == 0 else {
            try? fm.removeItem(at: baseStaging)
            try? fm.removeItem(at: templateStaging)
            throw SidekernelError.provisioning("base-build: could not publish the built images")
        }
        try fingerprint.write(to: stamp, atomically: true, encoding: .utf8)
        return (base, template)
    }

    private func assetFingerprint() throws -> String {
        var hasher = SHA256()
        let inputs = [Self.baseBuildScript(ubuntuTar: "UBUNTU", templateName: "TEMPLATE",
                                           sentinel: "SENTINEL"),
                      Base.rootfsURL.absoluteString]
        for input in inputs {
            hasher.update(data: Data(input.utf8))
            hasher.update(data: Data([0]))   // an unambiguous boundary between inputs
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Builder output lines `@@sk-step <key>` start these steps; no other guest output reaches the terminal.
    private static let buildSteps = ["packages": "Provisioning the microVM environment", "image": "Sealing the sandbox disk image"]
    private static let stepMarker = "@@sk-step"

    /// The script the builder VM runs as root: /workspace is the images dir, /dev/vda becomes sidekernel-base.
    static func baseBuildScript(ubuntuTar: String, templateName: String, sentinel: String) -> String {
        """
        set -e
        cd /workspace
        export DEBIAN_FRONTEND=noninteractive
        echo \(stepMarker) packages

        rm -rf /mnt/rootfs && mkdir -p /mnt/rootfs
        tar -xpf \(ubuntuTar) -C /mnt/rootfs
        cp /etc/resolv.conf /mnt/rootfs/etc/resolv.conf
        mount -t proc proc /mnt/rootfs/proc
        mount -t sysfs sys /mnt/rootfs/sys
        mount --bind /dev /mnt/rootfs/dev
        # Packages from the last build; apt checks each against its signed index before using it.
        mkdir -p debs
        cp debs/*.deb /mnt/rootfs/var/cache/apt/archives/ 2>/dev/null || true
        # No fsync per file; a failed build is thrown away anyway.
        echo force-unsafe-io > /mnt/rootfs/etc/dpkg/dpkg.cfg.d/sk-build
        # gpg checks the Claude key below.
        chroot /mnt/rootfs /bin/sh -c '
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq
          apt-get upgrade -y
          apt-get install -y --no-install-recommends \(Base.aptInstall.joined(separator: " ")) gpg
          apt-get autoremove -y
          apt-get autoclean -qq
          rm -rf /var/lib/apt/lists/*
        '
        rm -f /mnt/rootfs/etc/dpkg/dpkg.cfg.d/sk-build
        # Installed in the isolated builder: no host config or credentials are present.
        chroot /mnt/rootfs npm install -g @openai/codex@\(Codex.version)
        # Only this build's packages are kept for the next one, and none stay in the image.
        rm -f debs/*.deb
        cp /mnt/rootfs/var/cache/apt/archives/*.deb debs/ 2>/dev/null || true
        rm -f /mnt/rootfs/var/cache/apt/archives/*.deb

        # Trust the key only if it holds exactly one primary key with the pinned fingerprint.
        cp claude-code.asc /mnt/rootfs/tmp/claude-code.asc
        KEY_META=$(chroot /mnt/rootfs /bin/sh -c 'h=$(mktemp -d); gpg --homedir "$h" --show-keys --with-colons /tmp/claude-code.asc 2>/dev/null; rm -rf "$h" /tmp/claude-code.asc')
        PUB_COUNT=$(printf '%s\\n' "$KEY_META" | grep -c '^pub:' || true)
        KEY_FPR=$(printf '%s\\n' "$KEY_META" | awk -F: '/^fpr:/{print $10; exit}')
        if [ "$PUB_COUNT" != "1" ] || [ "$KEY_FPR" != "\(Claude.gpgKeyFingerprint)" ]; then
          echo "Claude apt key verification failed (pub=$PUB_COUNT fpr='$KEY_FPR')" >&2
          exit 1
        fi
        install -d -m 0755 /mnt/rootfs/etc/apt/keyrings
        cp claude-code.asc /mnt/rootfs/etc/apt/keyrings/claude-code.asc
        printf 'deb [signed-by=/etc/apt/keyrings/claude-code.asc] %s %s %s\\n' \
          '\(Claude.aptRepoURL)' '\(Claude.aptSuite)' '\(Claude.aptComponent)' \
          > /mnt/rootfs/etc/apt/sources.list.d/claude-code.list

        # /.sk ships empty so the overlay bind for `save` never forces a copy-up. The guest scripts come at boot.
        install -d -m 0755 /mnt/rootfs/.sk
        umount /mnt/rootfs/dev /mnt/rootfs/proc /mnt/rootfs/sys

        # Pack straight onto the attached sparse disk; PID 1 finds disks by label, never by order.
        echo \(stepMarker) image
        mkfs.ext4 -F -q -m 0 -L sk-base -d /mnt/rootfs /dev/vda
        sync
        e2fsck -fn /dev/vda >/dev/null 2>&1

        # The blank save-staging template PersonalStore clones per run.
        # ^metadata_csum: publishing a save rewrites the label bytes, which a checksum would invalidate.
        rm -f \(templateName)
        dd if=/dev/zero of=\(templateName) bs=1M count=0 seek=8192 2>/dev/null
        mkfs.ext4 -F -q -m 0 -O ^metadata_csum -L sk-staging \(templateName)
        sync
        : > \(sentinel)
        """
    }

    // MARK: - Builder VM

    private func runBuilder(name: String, kernel: URL, initramfs: URL, disk: URL,
                            script: String, sentinel: String, steps: Terminal.Steps) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appending(path: "\(name).log")
        try? fm.removeItem(at: log)
        fm.createFile(atPath: log.path, contents: nil)
        let logFd = open(log.path, O_WRONLY | O_APPEND)
        defer { if logFd >= 0 { close(logFd) } }
        let sentinelURL = images.appending(path: sentinel)
        try? fm.removeItem(at: sentinelURL)

        let vm = MicroVM(spec: VMSpec(
            kernelURL: kernel, initramfsURL: initramfs, baseImage: disk, baseReadOnly: false,
            personalImage: nil, stagingImage: nil, workspaceDir: images.path,
            overlayBoot: false, waitForNetwork: true, networkOn: true,
            cpuCount: 4, memoryMB: 8192))
        let started = Date()
        do {
            try vm.start()
        } catch {
            steps.finish(ok: false)
            Self.noteIfNATWedged(since: started, steps: steps)
            throw error
        }
        defer { try? vm.stop() }
        var built = false
        defer { steps.finish(ok: built) }

        let nonce = Contract.randomNonce()
        let held = FdBag()
        defer { held.closeAll() }
        let onStep: @Sendable (String) -> Void = { key in
            if let label = Self.buildSteps[key] { steps.start(label) }
        }
        try vm.listenService { fd in
            // Each drain thread owns a dup, so a straggler can never write to a recycled descriptor.
            let ownedLog = logFd >= 0 ? dup(logFd) : -1
            Thread {
                Self.serveBuilderStdio(fd: fd, nonce: nonce, logFd: ownedLog, held: held, onStep: onStep)
            }.start()
        }

        let control = try vm.dialControl(timeout: 90)
        defer { close(control) }
        FDIO.setReadTimeout(control, seconds: 3600)   // a wedged build fails loudly, not forever
        _ = FDIO.writeFrame(control, .helloExec(networkOn: true))
        _ = FDIO.writeFrame(control, .exec(nonce: nonce, workdir: "/",
                                           argv: ["/bin/sh", "-c", script], env: [],
                                           tty: false, cols: 0, rows: 0))
        var exitCode: Int32 = -1
        loop: while true {
            switch try FDIO.readFrame(control, cap: Contract.maxControlFrame) {
            case .started: continue
            case .exited(let code): exitCode = code; break loop
            case .error(let reason): throw SidekernelError.vm("\(name): guest refused exec: \(reason)")
            default: throw SidekernelError.agentProtocol("\(name): unexpected frame on the control connection")
            }
        }

        let sentinelSeen = fm.fileExists(atPath: sentinelURL.path)
        try? fm.removeItem(at: sentinelURL)
        guard exitCode == 0, sentinelSeen else {
            steps.finish(ok: false)
            Self.noteIfNATWedged(since: started, steps: steps)
            throw SidekernelError.provisioning("\(name) failed (exit \(exitCode)), see \(log.path)")
        }
        built = true
    }

    private static func serveBuilderStdio(fd: Int32, nonce: String, logFd: Int32, held: FdBag,
                                          onStep: (String) -> Void) {
        defer { if logFd >= 0 { close(logFd) } }
        FDIO.setReadTimeout(fd, seconds: 10)
        guard let hello = try? FDIO.readFrame(fd, cap: Contract.maxControlFrame),
              case .helloStdio(let which, let helloNonce) = hello, helloNonce == nonce
        else { close(fd); return }
        guard which == .stdout || which == .stderr else { held.add(fd); return }
        FDIO.setReadTimeout(fd, seconds: 3600)
        let marker = Array("\(stepMarker) ".utf8)
        var line: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { close(fd); return }
            if logFd >= 0 { _ = buf.withUnsafeBytes { write(logFd, $0.baseAddress, n) } }
            for byte in buf[..<n] {
                if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    if line.starts(with: marker) {
                        onStep(String(decoding: line.dropFirst(marker.count), as: UTF8.self))
                    }
                    line.removeAll(keepingCapacity: true)
                } else if line.count < 256 {
                    line.append(byte)
                }
            }
        }
    }

    private final class FdBag: @unchecked Sendable {
        private let lock = NSLock()
        private var fds: [Int32] = []
        func add(_ fd: Int32) { lock.lock(); fds.append(fd); lock.unlock() }
        func closeAll() { lock.lock(); fds.forEach { close($0) }; fds.removeAll(); lock.unlock() }
    }

    /// The macOS NAT wedge: a healthy boot always rewrites the lease db, a wedged one never does.
    static func noteIfNATWedged(since: Date, steps: Terminal.Steps) {
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: "/var/db/dhcpd_leases"))?[.modificationDate] as? Date
        if let modified, modified >= since { return }
        // Printed only: sidekernel never escalates itself; the sudo is the operator's own.
        steps.note("""
        No DHCP lease reached this VM. The macOS NAT service (InternetSharing) looks \
        wedged, a recurring macOS bug after long host uptime. Fix, then retry:
          sudo pkill InternetSharing
        """)
    }

    // MARK: - Tools

    static func runTool(_ tool: String, _ arguments: [String], fail: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let errors = Pipe()
        p.standardError = errors
        try p.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let reason = String(decoding: output, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)
            throw SidekernelError.provisioning(
                reason.map { "\(fail): \($0)" } ?? "\(fail) (\(tool) exit \(p.terminationStatus))")
        }
    }

    /// A megabyte at a time, so a multi-gigabyte image never lands in memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func makeSparseFile(at url: URL, gigabytes: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0, ftruncate(fd, off_t(gigabytes) << 30) == 0 else {
            if fd >= 0 { close(fd) }
            throw SidekernelError.provisioning("cannot create \(url.lastPathComponent)")
        }
        close(fd)
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Not Bundle.module: it traps when the bundle is neither beside Bundle.main nor at its
    /// build path, as in a relocated install such as Homebrew's libexec.
    static func bundledResource(_ name: String) throws -> URL {
        let exe = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/")).resolvingSymlinksInPath()
        let sibling = exe.deletingLastPathComponent().appending(path: "Sidekernel_Host.bundle")
        if let url = Bundle(url: sibling)?.url(forResource: name, withExtension: nil) { return url }
        throw SidekernelError.provisioning("bundled resource \(name) missing, rebuild with make")
    }

    private static func locked<T>(_ lockFile: URL, whileWaiting: (() -> Void)? = nil,
                                  _ body: () throws -> T) throws -> T {
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw SidekernelError.provisioning("cannot open \(lockFile.lastPathComponent)") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            whileWaiting?()
            guard flock(fd, LOCK_EX) == 0 else {
                close(fd)
                throw SidekernelError.provisioning("cannot take \(lockFile.lastPathComponent)")
            }
        }
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }
}

public struct Artifacts: Sendable {
    public let kernel: URL
    public let initramfs: URL
    public let baseImage: URL
    public let stagingTemplate: URL
    /// nil until the first save publishes one.
    public let personalImage: URL?
}
