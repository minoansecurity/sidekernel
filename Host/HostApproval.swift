import Foundation
import CoreGraphics

/// Every approval is a macOS dialog, out of the guest's reach and denying by default.
/// With no desktop session there is no one to ask, so the answer is no.
public final class HostApproval {
    static let timeout: TimeInterval = 60

    /// One prompt at a time; a request arriving while one is open is denied, not queued.
    private let serial = NSLock()

    public init() {}

    public func ask(_ message: String) -> Bool {
        guard serial.try() else { return false }
        defer { serial.unlock() }
        guard Self.aquaSessionExists else {
            Terminal.notice("sidekernel: denied, approvals need the Mac's desktop session")
            return false
        }
        return Self.askViaDialog(message)
    }

    static func appleScriptEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Without one, a dialog would fail silently.
    private static var aquaSessionExists: Bool {
        CGSessionCopyCurrentDictionary() != nil
    }

    private static func askViaDialog(_ message: String) -> Bool {
        let script = "display dialog \"\(message)\""
            + " buttons {\"Deny\", \"Allow\"} default button \"Deny\""
            + " with title \"SideKernel\" with icon caution"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(200_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let reply = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return reply.contains("Allow")
    }
}
