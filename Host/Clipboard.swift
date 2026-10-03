import AppKit

/// The guest may read an image only right after you press paste,
/// and may replace your clipboard only after you allow it on the host.
public enum Clipboard {
    public static func service(grant: ClipboardGrant?) -> Frame {
        guard let grant, grant.isLive, let png = pngData() else {
            return .ctlReply(status: .deny, message: "none", payload: [])
        }
        return .ctlReply(status: .ok, message: "", payload: Array(png))
    }

    public static func service(copy payload: [UInt8], approval: HostApproval) -> Frame {
        // Validate first, so junk never raises a dialog.
        guard let text = acceptText(payload) else {
            return .ctlReply(status: .deny,
                             message: "copy refused: plain text only (no control or invisible formatting characters)",
                             payload: [])
        }
        guard approval.ask(copyPrompt) else {
            return .ctlReply(status: .deny, message: "denied on the host", payload: [])
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .ctlReply(status: .err, message: "pasteboard write failed", payload: [])
        }
        // Said out loud, so a swapped clipboard is noticed before it is pasted.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        Terminal.notice("📋 the sandbox put \(lines) line\(lines == 1 ? "" : "s") on your clipboard")
        return .ctlReply(status: .ok, message: "", payload: [])
    }

    /// Plain text only: control bytes act wherever it is pasted, and invisible
    /// formatting (bidi overrides, zero-width) makes it read differently from what it does.
    static func acceptText(_ payload: [UInt8]) -> String? {
        guard let raw = String(bytes: payload, encoding: .utf8) else { return nil }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let clean = text.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control: return scalar == "\t" || scalar == "\n"
            case .format: return scalar == "\u{200D}"   // the joiner inside emoji sequences
            case .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        return clean ? text : nil
    }

    /// Guest text never appears in it, so it cannot pose as the dialog.
    static let copyPrompt = "SideKernel is requesting to copy text to your Mac's clipboard."

    // MARK: - Pasteboard

    private static func pngData() -> Data? {
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff) { return png(fromTIFF: tiff) }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation {
            return png(fromTIFF: tiff)
        }
        return nil
    }

    private static func png(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

/// The paste keystroke opens a short window for the guest to read an image.
public final class ClipboardGrant: @unchecked Sendable {
    /// Ctrl+V, Claude Code's image-paste key on Linux.
    static let pasteByte: UInt8 = 0x16
    // Codex may request Kitty/CSI-u or modifyOtherKeys reporting. Accept the same
    // Ctrl+V press/repeat as the legacy byte; a key release never opens a grant.
    // Keep in sync with PASTE_KEYS in guest/internal/harness.py.
    private static let pasteKeys = ["\u{1B}[118;5u", "\u{1B}[118;5:1u", "\u{1B}[118;5:2u",
                                    "\u{1B}[27;5;118~"].map { Array($0.utf8) } + [[pasteByte]]
    private static let pasteStart = Array("\u{1B}[200~".utf8)
    private static let pasteEnd = Array("\u{1B}[201~".utf8)
    private static let inputKeys = pasteKeys + [pasteStart]

    private let window: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var armedAt: Date?
    private var inputTail: [UInt8] = []
    private var bracketedPaste = false

    public convenience init() {
        self.init(window: 10, now: Date.init)
    }

    init(window: TimeInterval, now: @escaping () -> Date) {
        self.window = window
        self.now = now
    }

    public func noteInput(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        defer { lock.unlock() }
        for byte in bytes {
            // Ordinary text cannot be a paste key or terminal marker.
            if inputTail.isEmpty && byte != 0x1B && byte != Self.pasteByte { continue }
            inputTail.append(byte)
            while !inputTail.isEmpty {
                let keys = bracketedPaste ? [Self.pasteEnd] : Self.inputKeys
                if keys.contains(inputTail) {
                    if inputTail == Self.pasteStart { bracketedPaste = true }
                    else if inputTail == Self.pasteEnd { bracketedPaste = false }
                    else { armedAt = now() }
                    inputTail.removeAll(keepingCapacity: true)
                    break
                }
                if keys.contains(where: { $0.starts(with: inputTail) }) { break }
                inputTail.removeFirst()
            }
        }
    }

    public var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let armedAt else { return false }
        return now().timeIntervalSince(armedAt) < window
    }
}
