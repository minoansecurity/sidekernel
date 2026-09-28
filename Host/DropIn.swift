import Foundation
import Darwin

/// `sk-drop`: the one way a file or folder outside /workspace enters the guest, once a human agrees.
public enum DropIn {
    static let chunkSize = 1 << 20

    public static func service(rawPath: String, forbidden: [String],
                               approval: HostApproval, to connection: Int32) -> Frame {
        let fd: Int32, path: String, size: Int, isDir: Bool
        switch openPinned(rawPath, forbidden: forbidden) {
        case .refused(let why):
            return .ctlReply(status: .err, message: why, payload: [])
        case .pinned(let f, let p, let s, let d):
            (fd, path, size, isDir) = (f, p, s, d)
        }
        defer { close(fd) }

        let facts = "\(isDir ? "folder" : "file"), \(humanSize(size))"
        let allowed = approval.ask(
            "SideKernel: allow dropping\\n\(HostApproval.appleScriptEscape(path))\\n"
                + "(\(facts)) into the sandbox?")
        guard allowed else {
            return .ctlReply(status: .deny, message: "denied on the host", payload: [])
        }
        guard FDIO.writeFrame(connection, .ctlReply(status: .ok, message: isDir ? "dir" : "file", payload: [])),
              isDir ? tarPinned(fd, path: path, to: connection) : stream(fd, to: connection) else {
            return .ctlReply(status: .err, message: "copy failed", payload: [])
        }
        // An empty chunk ends the stream.
        return .ctlReply(status: .ok, message: "", payload: [])
    }

    private enum Candidate {
        case pinned(fd: Int32, path: String, size: Int, isDir: Bool)
        case refused(String)
    }

    /// Holds the inode open, so nothing can be swapped in after approval.
    private static func openPinned(_ raw: String, forbidden: [String]) -> Candidate {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return .refused("path must be absolute") }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .refused("no such file") }
        var status = stat()
        guard fstat(fd, &status) == 0 else { close(fd); return .refused("no such file") }
        // Name the inode from the open fd, never the guest's string, so the human sees the truth.
        let canonical = URL(fileURLWithPath: pathOfPinnedFd(fd) ?? path)
            .resolvingSymlinksInPath().path
        if forbidden.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) {
            close(fd)
            return .refused("already in the sandbox")
        }
        switch status.st_mode & S_IFMT {
        case S_IFREG:
            return .pinned(fd: fd, path: canonical, size: Int(status.st_size), isDir: false)
        case S_IFDIR:
            return .pinned(fd: fd, path: canonical, size: treeSize(canonical), isDir: true)
        default:
            close(fd)
            return .refused("not a regular file or folder")
        }
    }

    private static func treeSize(_ path: String) -> Int {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                        includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        while let url = walk.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }

    private static func pathOfPinnedFd(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func stream(_ source: Int32, to connection: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if n == 0 { return true }
            guard n > 0, FDIO.writeFrame(connection, .ctlReply(status: .ok, message: "",
                                                               payload: Array(buffer[0..<n]))) else { return false }
        }
    }

    /// Refuses if the path no longer names the pinned inode.
    private static func tarPinned(_ fd: Int32, path: String, to connection: Int32) -> Bool {
        var pinned = stat(), current = stat()
        guard fstat(fd, &pinned) == 0, stat(path, &current) == 0,
              pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino else { return false }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", path, "."]
        // Without this, bsdtar stores a junk `._name` twin for every extended attribute.
        tar.environment = ["COPYFILE_DISABLE": "1"]
        let pipe = Pipe()
        tar.standardOutput = pipe
        tar.standardError = FileHandle.nullDevice
        guard (try? tar.run()) != nil else { return false }

        let sent = stream(pipe.fileHandleForReading.fileDescriptor, to: connection)
        if !sent { tar.terminate() }
        tar.waitUntilExit()
        return sent && tar.terminationStatus == 0
    }

    static func humanSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
