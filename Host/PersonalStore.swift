import Foundation
import Darwin

/// The only way the guest's changes become the published personal disk.
public struct PersonalStore {
    private let directory: URL
    /// The personal image's inode at boot, so a concurrent sandbox's save is noticed.
    private let bootInode = InodeBox()

    public init(directory: URL) { self.directory = directory }

    private var image: URL { directory.appending(path: "personal/overlay.img") }
    private var sidecar: URL { directory.appending(path: "personal/listing") }
    private var lockFile: URL { directory.appending(path: "personal/.save.lock") }

    public func publish(staging: URL, personalIncluded: Bool, personalAttached: Bool) -> Frame {
        guard personalIncluded == personalAttached else {
            return reply(.err, "save refused: this sandbox booted without your personal layer. Exit and save from a fresh sandbox")
        }
        do {
            try withExclusiveLock(at: lockFile) {
                try sanityCheck(staging: staging)
                let published = inode(of: image)
                if bootInode.value == nil, published != nil {
                    throw Failure("a personal layer appeared since this sandbox booted. Exit and save from a fresh sandbox")
                }
                if let boot = bootInode.value, published != boot {
                    Terminal.notice("another sandbox saved while this one ran; this save overwrites it (last writer wins)")
                }
                // Clone, relabel, then rename into place, so no live image inode is written.
                let temp = image.deletingLastPathComponent().appending(path: "overlay.img.new")
                try clone(staging, to: temp)
                do { try relabel(temp) } catch { try? FileManager.default.removeItem(at: temp); throw error }
                guard rename(temp.path, image.path) == 0 else {
                    try? FileManager.default.removeItem(at: temp)
                    throw Failure("could not publish the personal image")
                }
            }
        } catch let failure as Failure {
            return reply(.err, failure.message)
        } catch {
            return reply(.err, "save failed: \(error.localizedDescription)")
        }
        return reply(.ok, "")
    }

    public func makeStagingClone(runID: String) throws -> URL {
        let runDir = directory.appending(path: "run")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let cloneURL = runDir.appending(path: "\(runID)-staging.img")
        do { try clone(Provisioning.stagingTemplate(root: directory), to: cloneURL) } catch {
            throw SidekernelError.provisioning("staging template missing or unreadable, rerun sidekernel to reprovision")
        }
        bootInode.value = inode(of: image)
        return cloneURL
    }

    public func currentImage() -> URL? {
        FileManager.default.fileExists(atPath: image.path) ? image : nil
    }

    // MARK: - Sanity check and relabel

    private func sanityCheck(staging: URL) throws {
        let fd = open(staging.path, O_RDONLY)
        guard fd >= 0 else { throw Failure("staging image missing. Was the sandbox torn down?") }
        defer { close(fd) }
        guard readAt(fd, offset: Contract.ext4MagicOffset, count: 2) == [0x53, 0xEF],
              readAt(fd, offset: Contract.ext4LabelOffset, count: 16) == label(Contract.labelStaging)
        else { throw Failure("staging image is not a settled sk-staging filesystem, run save again") }
    }

    private func relabel(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { throw Failure("cannot open the cloned image") }
        defer { close(fd) }
        guard pwrite(fd, label(Contract.labelPersonal), 16, off_t(Contract.ext4LabelOffset)) == 16,
              fsync(fd) == 0 else { throw Failure("could not relabel the cloned image") }
    }

    private func label(_ name: String) -> [UInt8] {
        Array(name.utf8) + [UInt8](repeating: 0, count: 16 - name.utf8.count)
    }

    private func readAt(_ fd: Int32, offset: UInt64, count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        return pread(fd, &buf, count, off_t(offset)) == count ? buf : nil
    }

    private func clone(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        if clonefile(source.path, destination.path, 0) == 0 { return }
        do { try FileManager.default.copyItem(at: source, to: destination) } catch {
            throw Failure("cannot stage \(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Listing

    public struct Listing: Sendable {
        public let total: String
        public let entries: [(size: String, path: String)]
    }

    public func listing() throws -> Listing {
        guard currentImage() != nil else {
            throw SidekernelError.provisioning("no personal layer yet, run `save` inside a sandbox first")
        }
        let text = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return Listing(total: "0", entries: []) }
        let total = Self.terminalSafe(lines.removeFirst()).trimmingCharacters(in: .whitespaces)
        let entries: [(size: String, path: String)] = lines.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (size: Self.terminalSafe(parts[0]), path: Self.terminalSafe(parts[1]))
        }
        return Listing(total: total, entries: entries)
    }

    /// Capped, so a hostile guest cannot balloon it. Opened without following a symlink
    /// or blocking on a FIFO, so only a regular file the guest wrote is read.
    public func ingestListing(fromProjectState projectDir: URL) {
        let source = projectDir.appending(path: "save-listing").path
        defer { unlink(source) }
        let fd = open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        if let data = try? handle.read(upToCount: 65_536),
           let text = String(data: data, encoding: .utf8) {
            recordListing(text)
        }
    }

    func recordListing(_ text: String) {
        try? Data(text.prefix(65_536).utf8).write(to: sidecar, options: .atomic)
    }

    /// A crafted filename could smuggle escapes onto the screen.
    static func terminalSafe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
        }))
    }

    // MARK: - Helpers

    private struct Failure: Error { let message: String; init(_ m: String) { message = m } }
    private final class InodeBox: @unchecked Sendable { var value: ino_t? }

    private func inode(of url: URL) -> ino_t? {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_ino : nil
    }

    private func reply(_ status: CtlStatus, _ message: String) -> Frame {
        .ctlReply(status: status, message: message, payload: [])
    }

    private func withExclusiveLock(at lockFile: URL, _ body: () throws -> Void) throws {
        try FileManager.default.createDirectory(
            at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX) == 0 else {
            if fd >= 0 { close(fd) }
            throw Failure("cannot take the personal-store lock")
        }
        defer { flock(fd, LOCK_UN); close(fd) }
        try body()
    }
}
