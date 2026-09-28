import Foundation
import Virtualization

public struct VMSpec {
    public var kernelURL: URL
    public var initramfsURL: URL
    public var baseImage: URL
    public var baseReadOnly: Bool
    public var personalImage: URL?
    public var stagingImage: URL?
    public var workspaceDir: String?
    public var projectDir: URL?
    public var seedDir: URL?
    public var overlayBoot: Bool
    public var waitForNetwork: Bool
    public var networkOn: Bool
    public var cpuCount: Int
    public var memoryMB: Int

    public init(kernelURL: URL, initramfsURL: URL, baseImage: URL,
                baseReadOnly: Bool, personalImage: URL?,
                stagingImage: URL?, workspaceDir: String?,
                projectDir: URL? = nil, seedDir: URL? = nil,
                overlayBoot: Bool, waitForNetwork: Bool,
                networkOn: Bool, cpuCount: Int, memoryMB: Int) {
        self.kernelURL = kernelURL
        self.initramfsURL = initramfsURL
        self.baseImage = baseImage
        self.baseReadOnly = baseReadOnly
        self.personalImage = personalImage
        self.stagingImage = stagingImage
        self.workspaceDir = workspaceDir
        self.projectDir = projectDir
        self.seedDir = seedDir
        self.overlayBoot = overlayBoot
        self.waitForNetwork = waitForNetwork
        self.networkOn = networkOn
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
    }
}

public final class MicroVM: NSObject {
    private let spec: VMSpec
    private let vmQueue: DispatchQueue
    private let id: String
    private let consoleLog: URL
    private nonisolated(unsafe) var vm: VZVirtualMachine?
    /// Virtualization retains neither the listener nor its delegate, so this class holds both.
    private nonisolated(unsafe) var serviceListener: VZVirtioSocketListener?
    private nonisolated(unsafe) var serviceDelegate: ServiceAcceptDelegate?

    public init(spec: VMSpec) {
        self.spec = spec
        self.id = "sk-vm-\(UUID().uuidString.prefix(8))"
        self.vmQueue = DispatchQueue(label: "sidekernel.vm.\(id)")
        self.consoleLog = FileManager.default.temporaryDirectory.appending(path: "\(id)-console.log")
        super.init()
    }

    // MARK: - Lifecycle

    public func start() throws {
        let configuration = try buildConfiguration()
        try configuration.validate()

        let done = DispatchSemaphore(value: 0)
        var startError: Error?
        vmQueue.sync {
            let machine = VZVirtualMachine(configuration: configuration, queue: vmQueue)
            machine.delegate = self
            vm = machine
            machine.start { result in
                if case .failure(let error) = result { startError = error }
                done.signal()
            }
        }
        done.wait()
        if let error = startError {
            throw SidekernelError.vm("vm start failed: \(error.localizedDescription)")
        }
        // Without this, an abrupt exit orphans the helper process and pins guest RAM until reboot.
        SignalReaper.shared.register(self)
    }

    public func stop() throws {
        guard let vm = vm else { return }
        self.vm = nil
        SignalReaper.shared.unregister(self)
        serviceListener = nil
        serviceDelegate = nil

        let done = DispatchSemaphore(value: 0)
        var stopError: Error?
        vmQueue.sync {
            vm.stop { error in
                stopError = error
                done.signal()
            }
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            FileHandle.standardError.write(Data(
                "sidekernel: vm stop timed out. A Virtualization helper process may linger until reboot.\n".utf8))
            return
        }
        if let error = stopError {
            throw SidekernelError.vm("vm stop failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Network posture

    /// Plugs the virtual cable from the hypervisor side, out of the guest's reach.
    public func setNetwork(on: Bool) -> Bool {
        let flipped: Bool = vmQueue.sync {
            guard let vm = vm else { return false }
            vm.networkDevices.first?.attachment = on ? VZNATNetworkDeviceAttachment() : nil
            return true
        }
        guard flipped else { return false }
        // Only a hint for the guest's DHCP loop; the attachment above is what enforces it.
        if let fd = try? dialGuest() {
            FDIO.writeFrame(fd, .helloNetChanged(on: on))
            close(fd)
        }
        return true
    }

    // MARK: - Vsock

    public func dialControl(timeout: TimeInterval) throws -> Int32 {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let fd = try? dialGuest() { return fd }
            usleep(20_000)
        } while Date() < deadline
        printConsoleTail(lines: 40)
        throw SidekernelError.timeout("guest agent did not answer within \(Int(timeout))s")
    }

    public func dialGuest() throws -> Int32 {
        guard let vm = vm else { throw SidekernelError.vm("vm is not running") }
        let done = DispatchSemaphore(value: 0)
        var dialedFd: Int32 = -1
        vmQueue.sync {
            guard let vsock = vm.socketDevices.first as? VZVirtioSocketDevice else {
                done.signal()
                return
            }
            vsock.connect(toPort: Contract.controlPort) { result in
                if case .success(let connection) = result {
                    dialedFd = dup(connection.fileDescriptor)
                    connection.close()
                }
                done.signal()
            }
        }
        done.wait()
        guard dialedFd >= 0 else { throw SidekernelError.vm("vsock connect to guest:\(Contract.controlPort) refused") }
        return dialedFd
    }

    public func listenService(onConnection: @escaping @Sendable (Int32) -> Void) throws {
        try vmQueue.sync {
            guard let vm = vm, let vsock = vm.socketDevices.first as? VZVirtioSocketDevice else {
                throw SidekernelError.vm("vm is not running")
            }
            let delegate = ServiceAcceptDelegate(onConnection: onConnection)
            let listener = VZVirtioSocketListener()
            listener.delegate = delegate
            serviceDelegate = delegate
            serviceListener = listener
            vsock.setSocketListener(listener, forPort: Contract.servicePort)
        }
    }

    // MARK: - Configuration

    /// The request, capped so an 8 GB Mac keeps 4 GB for itself and Virtualization accepts it.
    static func memorySize(requestedMB: Int) -> UInt64 {
        let mib: UInt64 = 1 << 20
        let physical = ProcessInfo.processInfo.physicalMemory
        let hostShare = physical > 6 << 30 ? physical - (4 << 30) : physical / 2
        let size = min(UInt64(max(requestedMB, 1)) * mib, hostShare,
                       VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        // Whole MiB, as Virtualization requires.
        return max(size / mib * mib, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
    }

    private func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = min(max(spec.cpuCount, 1), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = Self.memorySize(requestedMB: spec.memoryMB)
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.serialPorts = [buildConsolePort()]

        let bootLoader = VZLinuxBootLoader(kernelURL: spec.kernelURL)
        bootLoader.initialRamdiskURL = spec.initramfsURL
        bootLoader.commandLine = kernelCommandLine()
        configuration.bootLoader = bootLoader

        configuration.storageDevices = try buildDisks()

        var shares: [VZDirectorySharingDeviceConfiguration] = []
        if let workspaceDir = spec.workspaceDir {
            if let folders = HomeShare.folders(for: workspaceDir) {
                let device = VZVirtioFileSystemDeviceConfiguration(tag: "workspace")
                device.share = VZMultipleDirectoryShare(directories: folders)
                shares.append(device)
            } else {
                shares.append(Self.share(tag: "workspace", url: URL(fileURLWithPath: workspaceDir), readOnly: false))
            }
        }
        // Share roots the guest cannot re-point: the host never writes inside the project share,
        // and it builds the seed fresh each boot in a place the guest can only read.
        if let projectDir = spec.projectDir {
            shares.append(Self.share(tag: Contract.tagProject, url: projectDir, readOnly: false))
        }
        if let seedDir = spec.seedDir {
            shares.append(Self.share(tag: Contract.tagSeed, url: seedDir, readOnly: true))
        }
        configuration.directorySharingDevices = shares

        // The device always exists so the guest boots the same way, but a pinned boot never
        // attaches it; attach-then-detach would open a real egress window.
        let network = VZVirtioNetworkDeviceConfiguration()
        if spec.networkOn { network.attachment = VZNATNetworkDeviceAttachment() }
        configuration.networkDevices = [network]

        return configuration
    }

    private static func share(tag: String, url: URL, readOnly: Bool) -> VZVirtioFileSystemDeviceConfiguration {
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: url, readOnly: readOnly))
        return device
    }

    /// Only staging is writable; the save model depends on it.
    private func buildDisks() throws -> [VZStorageDeviceConfiguration] {
        var attachments = [try VZDiskImageStorageDeviceAttachment(
            url: spec.baseImage, readOnly: spec.baseReadOnly)]
        if let personal = spec.personalImage {
            attachments.append(try VZDiskImageStorageDeviceAttachment(url: personal, readOnly: true))
        }
        if let staging = spec.stagingImage {
            attachments.append(try VZDiskImageStorageDeviceAttachment(url: staging, readOnly: false))
        }
        return attachments.map(VZVirtioBlockDeviceConfiguration.init)
    }

    private func kernelCommandLine() -> String {
        var tokens = ["console=hvc0", "tsc=reliable", "panic=-1", "rdinit=/sbin/sk-agent"]
        if spec.overlayBoot { tokens.append(Contract.cmdlineOverlay) }
        // Never wait for a lease that cannot arrive: eth0 still enumerates on a nil attachment.
        if spec.waitForNetwork && spec.networkOn { tokens.append(Contract.cmdlineNetwait) }
        return tokens.joined(separator: " ")
    }

    /// The only view of a boot that fails.
    private func buildConsolePort() -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        if let attachment = try? VZFileSerialPortAttachment(url: consoleLog, append: false) {
            console.attachment = attachment
        }
        return console
    }

    private func printConsoleTail(lines: Int) {
        guard let text = try? String(contentsOf: consoleLog, encoding: .utf8) else { return }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
        FileHandle.standardError.write(Data(
            ("\n── guest console (tail) ──\n" + tail.joined(separator: "\n") + "\n").utf8))
    }
}

/// Required but empty: teardown goes through stop().
extension MicroVM: VZVirtualMachineDelegate {
    public func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {}
    public func guestDidStop(_ vm: VZVirtualMachine) {}
}

private final class ServiceAcceptDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private let onConnection: @Sendable (Int32) -> Void

    init(onConnection: @escaping @Sendable (Int32) -> Void) {
        self.onConnection = onConnection
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from device: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        connection.close()
        guard fd >= 0 else { return false }
        onConnection(fd)
        return true
    }
}

/// With ~ as the folder, /workspace is every top-level folder of ~ except SideKernel's own state.
/// One VirtioFS share cannot leave a subfolder out, so ~ is shared folder by folder: top-level
/// files are not shared, /workspace itself takes no new entries, and new folders need a new sk.
enum HomeShare {
    static let hidden: Set<String> = [".sidekernel"]

    static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    }

    /// nil unless `dir` is the home folder.
    static func folders(for dir: String) -> [String: VZSharedDirectory]? {
        let home = home
        guard URL(fileURLWithPath: dir).resolvingSymlinksInPath().path == home,
              let names = try? FileManager.default.contentsOfDirectory(atPath: home) else { return nil }
        var folders: [String: VZSharedDirectory] = [:]
        for name in names where isShared(name, in: home) {
            folders[name] = VZSharedDirectory(url: URL(fileURLWithPath: "\(home)/\(name)"), readOnly: false)
        }
        return folders
    }

    /// Whether a canonical host path under ~ shows up in /workspace when ~ is the folder.
    static func shows(_ canonical: String) -> Bool {
        let home = home
        guard canonical.hasPrefix(home + "/") else { return canonical == home }
        let name = String(canonical.dropFirst(home.count + 1).prefix { $0 != "/" })
        return isShared(name, in: home)
    }

    /// Real folders only: a symlink would lead the share out of ~. Folders macOS will not
    /// open for us (~/.Trash without Full Disk Access) make the whole share invalid.
    private static func isShared(_ name: String, in home: String) -> Bool {
        guard !hidden.contains(name), (try? VZMultipleDirectoryShare.validateName(name)) != nil else { return false }
        let path = "\(home)/\(name)"
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return false }
        guard let dir = opendir(path) else { return false }
        closedir(dir)
        return true
    }
}
