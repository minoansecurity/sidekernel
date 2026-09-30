import Foundation
import Darwin

/// Links a folder to its harness configs by an ID in an xattr, which survives renames and
/// moves on the same disk without writing inside the folder.
enum ProjectIdentity {
    /// `#P` tells macOS never to copy it, so a copied folder starts its own project.
    static let attribute = "com.sidekernel.project#P"
    static let projects = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".sidekernel/projects")

    static func stateDir(for hostDir: String) throws -> URL {
        let folder = URL(fileURLWithPath: hostDir).resolvingSymlinksInPath().path
        return projects.appending(path: try readID(folder) ?? stamp(folder))
    }

    /// Only an ID shaped like ours: the guest can rewrite it through /workspace.
    private static func readID(_ folder: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = getxattr(folder, attribute, &buffer, buffer.count, 0, 0)
        guard count == 32 else { return nil }
        let id = String(decoding: buffer[..<count], as: UTF8.self)
        return id.allSatisfy { "0123456789abcdef".contains($0) } ? id : nil
    }

    private static func stamp(_ folder: String) throws -> String {
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let bytes = Array(id.utf8)
        guard setxattr(folder, attribute, bytes, bytes.count, 0, 0) == 0 else {
            throw SidekernelError.provisioning(
                "cannot tag \(folder) with its project id: \(String(cString: strerror(errno)))")
        }
        return id
    }
}
