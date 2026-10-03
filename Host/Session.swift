import Foundation
import Darwin

public final class Session {
    private let vm: MicroVM
    private let grant: ClipboardGrant?

    private let stateLock = NSLock()
    private var armedNonce: String?
    private var armedDeadline: DispatchTime = .now()
    private var claimedFds: [Int32] = [-1, -1]
    private let claims = DispatchSemaphore(value: 0)

    public init(vm: MicroVM, grant: ClipboardGrant?) {
        self.vm = vm
        self.grant = grant
    }

    public func run(controlFd: Int32, command: [String], workDir: String,
                    env: [String], networkOn: Bool, tty: Bool, forwardStdin: Bool = true) throws -> Int32 {
        defer { close(controlFd) }
        guard FDIO.writeFrame(controlFd, .helloExec(networkOn: networkOn)) else {
            throw SidekernelError.agentProtocol("control connection closed before hello")
        }

        let interactive = tty && isatty(STDIN_FILENO) != 0
        // The size rides in Exec, so the PTY is sized before the fork and a TUI never re-flows.
        let size = interactive ? Terminal.windowSize() : nil
        let nonce = Contract.randomNonce()
        arm(nonce: nonce, streams: interactive ? 2 : 3)
        defer { disarm() }

        guard FDIO.writeFrame(controlFd, .exec(nonce: nonce, workdir: workDir, argv: command,
                                               env: env, tty: interactive,
                                               cols: size?.cols ?? 80, rows: size?.rows ?? 24)) else {
            throw SidekernelError.agentProtocol("control connection closed before exec")
        }
        switch try FDIO.readFrame(controlFd, cap: Contract.maxControlFrame) {
        case .started: break
        case .error(let reason): throw SidekernelError.agentProtocol("guest refused exec: \(reason)")
        default: throw SidekernelError.agentProtocol("unexpected reply to Exec")
        }
        let fds = try awaitStdio()
        let stdinFd = fds[0]
        defer { fds.forEach { close($0) } }
        let forwardInput = forwardStdin && (interactive || isatty(STDIN_FILENO) == 0)
        let inputFd = forwardInput ? dup(stdinFd) : -1
        guard !forwardInput || inputFd >= 0 else {
            throw SidekernelError.agentProtocol("cannot duplicate stdin connection")
        }

        let terminal = interactive ? SessionTerminal(networkOn: networkOn) : nil
        defer { terminal?.restore() }

        let outputDone = DispatchSemaphore(value: 0)
        for (fd, destination) in zip(fds.dropFirst(), [STDOUT_FILENO, STDERR_FILENO]) {
            let filtered = Self.filtersGuestOutput(to: destination, interactive: interactive)
            Thread {
                if filtered { Self.pumpGuestOutput(from: fd, to: destination) }
                else { FDIO.pump(from: fd, to: destination) }
                outputDone.signal()
            }.start()
        }
        // Quiet provisioning must not consume a piped prompt intended for the later harness run.
        // Each pump owns its socket, so session teardown cannot recycle an fd beneath it.
        if forwardInput {
            let grant = grant
            Thread {
                defer { close(inputFd) }
                Self.pumpOperatorInput(from: STDIN_FILENO, to: inputFd, grant: grant)
            }.start()
        } else {
            shutdown(stdinFd, Int32(SHUT_WR))
        }
        var winch: DispatchSourceSignal?
        if interactive { winch = installResizeForwarder(controlFd: controlFd) }

        var clean = false
        defer {
            winch?.cancel()
            if clean {
                // Exit raced the last output bytes: drain, bounded so a wedged guest agent cannot hang us.
                fds.dropFirst().forEach { FDIO.setReadTimeout($0, seconds: 5) }
            } else {
                fds.dropFirst().forEach { shutdown($0, Int32(SHUT_RDWR)) }
                shutdown(stdinFd, Int32(SHUT_RDWR))
            }
            for _ in fds.dropFirst() { outputDone.wait() }
        }

        guard case .exited(let code) = try FDIO.readFrame(controlFd, cap: Contract.maxControlFrame) else {
            throw SidekernelError.agentProtocol("unexpected frame while waiting for exit")
        }
        clean = true
        return code
    }

    /// Only a matching nonce, inside the window, for a stream not yet claimed.
    public func claimStdio(which: StdioStream, nonce: String, fd: Int32) -> Bool {
        stateLock.lock()
        let accepted = armedNonce == nonce && DispatchTime.now() < armedDeadline
            && Int(which.rawValue) < claimedFds.count
            && claimedFds[Int(which.rawValue)] < 0
        if accepted { claimedFds[Int(which.rawValue)] = fd }
        stateLock.unlock()
        if accepted { claims.signal() } else { close(fd) }
        return accepted
    }

    private func arm(nonce: String, streams: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        armedNonce = nonce
        armedDeadline = .now() + .seconds(5)
        claimedFds = Array(repeating: -1, count: streams)
    }

    private func awaitStdio() throws -> [Int32] {
        stateLock.lock()
        let deadline = armedDeadline
        let streams = claimedFds.count
        stateLock.unlock()
        for _ in 0..<streams {
            guard claims.wait(timeout: deadline) == .success else {
                throw SidekernelError.timeout("guest never connected exec stdio")
            }
        }
        stateLock.lock(); defer { stateLock.unlock() }
        let fds = claimedFds
        claimedFds = [-1, -1]
        armedNonce = nil
        return fds
    }

    private func disarm() {
        stateLock.lock()
        armedNonce = nil
        let leftover = claimedFds
        claimedFds = [-1, -1]
        stateLock.unlock()
        for fd in leftover where fd >= 0 { close(fd) }
    }

    /// A terminal honours escapes whether or not stdin is one, so a piped prompt still filters.
    static func filtersGuestOutput(to fd: Int32, interactive: Bool) -> Bool {
        interactive || isatty(fd) != 0
    }

    static func pumpGuestOutput(from: Int32, to: Int32) {
        var filter = GuestOutputFilter()
        var buffer = [UInt8](repeating: 0, count: 4096)
        func emit(_ bytes: [UInt8]) -> Bool {
            guard !bytes.isEmpty else { return true }
            Terminal.outputLock.lock(); defer { Terminal.outputLock.unlock() }
            return FDIO.writeAll(to, bytes)
        }
        while true {
            let n = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, 4096) }
            guard n > 0 else { break }
            guard emit(filter.feed(buffer[0..<n])) else { return }
        }
        _ = emit(filter.flush())
    }

    /// The only stdin reader; the paste keystroke is noted before the VM sees it.
    static func pumpOperatorInput(from source: Int32, to fd: Int32, grant: ClipboardGrant?) {
        // Half-close only input: output and the process exit still need to drain.
        defer { shutdown(fd, Int32(SHUT_WR)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, 4096) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            grant?.noteInput(buffer[0..<n])
            guard FDIO.writeAll(fd, Array(buffer[0..<n])) else { break }
        }
    }

    private func installResizeForwarder(controlFd: Int32) -> DispatchSourceSignal {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        source.setEventHandler {
            guard let size = Terminal.windowSize() else { return }
            FDIO.writeFrame(controlFd, .resize(cols: size.cols, rows: size.rows))
        }
        source.resume()
        return source
    }

    fileprivate static func writeToTerminal(_ text: String) {
        Terminal.outputLock.lock(); defer { Terminal.outputLock.unlock() }
        FDIO.writeAll(STDERR_FILENO, Array(text.utf8))
    }
}

/// Raw mode and the session title, undone exactly once.
final class SessionTerminal {
    private var saved = termios()
    private var restored = false

    init(networkOn: Bool) {
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        SignalReaper.shared.setTerminalRestore(Self.makeRestore(saved))
        Session.writeToTerminal(Terminal.sessionEnter(networkOn: networkOn))
    }

    func restore() {
        guard !restored else { return }
        restored = true
        SignalReaper.shared.setTerminalRestore(nil)
        Self.makeRestore(saved)()
    }

    /// TCSAFLUSH drops keystrokes typed into the dying session.
    private static func makeRestore(_ saved: termios) -> () -> Void {
        {
            var settings = saved
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings)
            Session.writeToTerminal(Terminal.sessionLeave())
        }
    }
}

public enum FDIO {
    public static func readFull(_ fd: Int32, count: Int) -> [UInt8]? {
        guard count > 0 else { return count == 0 ? [] : nil }
        var buffer = [UInt8](repeating: 0, count: count)
        let complete = buffer.withUnsafeMutableBytes { raw -> Bool in
            var got = 0
            while got < count {
                let n = read(fd, raw.baseAddress! + got, count - got)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return complete ? buffer : nil
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        return bytes.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    public static func readFrame(_ fd: Int32, cap: Int) throws -> Frame {
        guard let header = readFull(fd, count: 4) else {
            throw SidekernelError.agentProtocol("connection closed")
        }
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard length >= 1, length <= cap else {
            throw SidekernelError.agentProtocol("frame length out of bounds: \(length)")
        }
        guard let payload = readFull(fd, count: length) else {
            throw SidekernelError.agentProtocol("connection closed mid-frame")
        }
        do { return try Frame.decodePayload(payload[...]) }
        catch let error as FrameDecodeError {
            throw SidekernelError.agentProtocol("bad frame: \(error.reason)")
        }
    }

    @discardableResult
    public static func writeFrame(_ fd: Int32, _ frame: Frame) -> Bool {
        guard let bytes = frame.encode() else { return false }
        return writeAll(fd, bytes)
    }

    /// Zero clears the timeout.
    public static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func splice(_ a: Int32, _ b: Int32) {
        let done = DispatchSemaphore(value: 0)
        Thread {
            pump(from: a, to: b, bufferSize: 16384)
            shutdown(a, Int32(SHUT_RDWR)); shutdown(b, Int32(SHUT_RDWR))
            done.signal()
        }.start()
        pump(from: b, to: a, bufferSize: 16384)
        shutdown(a, Int32(SHUT_RDWR)); shutdown(b, Int32(SHUT_RDWR))
        done.wait()
    }

    /// Leaves both fds open.
    static func pump(from: Int32, to: Int32, bufferSize: Int = 4096) {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, bufferSize) }
            guard n > 0, writeAll(to, Array(buffer[0..<n])) else { return }
        }
    }
}

/// On a fatal signal, restore the terminal and stop the VM.
final class SignalReaper {
    static let shared = SignalReaper()

    private let lock = NSLock()
    private var vm: MicroVM?
    private var terminalRestore: (() -> Void)?
    private var sources: [DispatchSourceSignal] = []
    private var installed = false

    private init() {}

    func register(_ vm: MicroVM) {
        lock.lock(); defer { lock.unlock() }
        self.vm = vm
        installIfNeeded()
    }

    func unregister(_ vm: MicroVM) {
        lock.lock(); defer { lock.unlock() }
        if self.vm === vm { self.vm = nil }
    }

    func setTerminalRestore(_ restore: (() -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        terminalRestore = restore
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        // A peer resetting mid-write would otherwise kill the process outright and skip teardown.
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGHUP, SIGTERM, SIGINT, SIGQUIT] {
            // A dispatch source, not a handler: calling into Virtualization needs a normal queue.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in self?.drainAndExit(signal: sig) }
            source.resume()
            sources.append(source)
        }
    }

    private func drainAndExit(signal sig: Int32) -> Never {
        lock.lock()
        let restore = terminalRestore
        let live = vm
        lock.unlock()
        restore?()
        try? live?.stop()
        exit(128 + sig)
    }
}
