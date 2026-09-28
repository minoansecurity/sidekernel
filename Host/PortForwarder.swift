import Foundation
import Darwin

/// A guest dev server becomes a loopback listener on the Mac, never the LAN, on the same port.
/// A port the Mac already uses is left alone rather than moved, so nothing answers in its place.
public final class PortForwarder: @unchecked Sendable {
    public enum Outcome: Sendable { case forwarded, lowPort, inUse, failed(String) }

    private let vm: MicroVM
    private let onOpen: (@Sendable (UInt16, Outcome) -> Void)?
    private let lock = NSLock()
    private var listeners: [UInt16: Int32] = [:]
    private var running = true

    public init(vm: MicroVM, onOpen: (@Sendable (UInt16, Outcome) -> Void)?) {
        self.vm = vm
        self.onOpen = onOpen
    }

    public func handleEvents(_ fd: Int32) {
        defer { close(fd) }
        while isRunning() {
            guard let frame = try? FDIO.readFrame(fd, cap: Contract.maxControlFrame),
                  case .portEvent(let port, let open) = frame else { break }
            if open { openForward(guestPort: port) } else { closeForward(guestPort: port) }
        }
        if isRunning() { Terminal.notice("port-event stream lost; waiting for the sandbox to reconnect") }
    }

    public func stop() {
        lock.lock()
        running = false
        let fds = Array(listeners.values)
        listeners.removeAll()
        lock.unlock()
        for fd in fds { close(fd) }
    }

    // MARK: - Forward lifecycle

    static let lowestForwarded: UInt16 = 1024

    private func openForward(guestPort: UInt16) {
        guard guestPort >= Self.lowestForwarded else { onOpen?(guestPort, .lowPort); return }
        lock.lock()
        if listeners[guestPort] != nil { lock.unlock(); return }
        lock.unlock()

        let listenFd: Int32
        switch Self.bindLoopback(port: guestPort) {
        case .bound(let fd): listenFd = fd
        case .refused(let outcome): onOpen?(guestPort, outcome); return
        }
        lock.lock()
        guard running, listeners[guestPort] == nil else { lock.unlock(); close(listenFd); return }
        listeners[guestPort] = listenFd
        lock.unlock()

        onOpen?(guestPort, .forwarded)
        Thread { [weak self] in self?.acceptLoop(listenFd: listenFd, guestPort: guestPort) }.start()
    }

    private func closeForward(guestPort: UInt16) {
        lock.lock()
        let fd = listeners.removeValue(forKey: guestPort)
        lock.unlock()
        if let fd { close(fd) }
    }

    private static func bindLoopback(port: UInt16) -> Bind {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return .refused(.failed(String(cString: strerror(errno)))) }
        // No SO_REUSEADDR: on macOS it lets 127.0.0.1:X bind beside a Mac service on *:X and steal its
        // loopback traffic. Without it a taken port fails here.
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound == 0 && listen(fd, 16) == 0 { return .bound(fd) }
        let code = errno
        close(fd)
        return .refused(code == EADDRINUSE ? .inUse : .failed(String(cString: strerror(code))))
    }

    private enum Bind { case bound(Int32), refused(Outcome) }

    /// Checks the listener is still ours on every accept.
    private func acceptLoop(listenFd: Int32, guestPort: UInt16) {
        while isRunning() {
            let conn = accept(listenFd, nil, nil)
            if conn < 0 { break }
            lock.lock()
            let stillOurs = listeners[guestPort] == listenFd
            lock.unlock()
            guard stillOurs else { close(conn); break }
            Thread { [weak self] in self?.tunnel(tcpConn: conn, guestPort: guestPort) }.start()
        }
    }

    private func tunnel(tcpConn: Int32, guestPort: UInt16) {
        guard let vsockFd = try? vm.dialGuest() else { close(tcpConn); return }
        guard FDIO.writeFrame(vsockFd, .helloTunnel(port: guestPort)) else {
            close(tcpConn)
            close(vsockFd)
            return
        }
        FDIO.splice(tcpConn, vsockFd)
        close(tcpConn)
        close(vsockFd)
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}
