import Foundation

/// Strips mouse-tracking, clipboard and title escapes from guest output.
public struct GuestOutputFilter {
    /// OSC 52 openers: 7-bit, C1, and UTF-8 C1.
    private static let openers: [[UInt8]] = [
        [0x1B, 0x5D, 0x35, 0x32, 0x3B],   // ESC ] 5 2 ;
        [0x9D, 0x35, 0x32, 0x3B],         // C1 OSC 5 2 ;
        [0xC2, 0x9D, 0x35, 0x32, 0x3B],   // UTF-8 C1 OSC 5 2 ;
    ]
    /// X10, button-event, any-motion tracking and the SGR/urxvt coordinate encodings.
    private static let mouseEnables: [[UInt8]] =
        ["\u{1B}[?1000h", "\u{1B}[?1002h", "\u{1B}[?1003h", "\u{1B}[?1006h", "\u{1B}[?1015h"]
            .map { Array($0.utf8) }
    /// OSC 0, 1 and 2, which would overwrite the host's status title. 7-bit only: a raw C1 byte
    /// is ambiguous with UTF-8 continuation bytes, and no terminal here reads it as OSC.
    private static let titleOpeners: [[UInt8]] =
        ["\u{1B}]0;", "\u{1B}]1;", "\u{1B}]2;"].map { Array($0.utf8) }
    private static let watched = openers + mouseEnables + titleOpeners

    private static let bel: UInt8 = 0x07
    private static let esc: UInt8 = 0x1B
    private static let st8: UInt8 = 0x9C
    private static let backslash: UInt8 = 0x5C

    /// Past this, an unterminated clipboard sequence is abandoned.
    private static let clipboardCap = 1 << 20
    /// Past this, an unterminated title is abandoned, so it cannot eat the session.
    private static let titleCap = 2048

    private static func extends(_ cand: [UInt8]) -> Bool {
        watched.contains { $0.count > cand.count && $0.starts(with: cand) }
    }

    private enum State {
        /// Ordinary output, with the watched-string bytes the tail matches so far.
        case idle(matched: [UInt8])
        /// OSC 52, read or write: swallow through to its terminator. Clipboard writes go through `sk-agent ctl
        /// copy` instead, where the host sees them.
        case dropping(seen: Int)
        case droppingEsc
        /// A title: swallow through BEL or ESC \, never a raw 0x9C, which UTF-8 text contains.
        case droppingTitle(seen: Int)
        case droppingTitleEsc
    }
    private var state: State = .idle(matched: [])

    public init() {}

    public mutating func feed(_ chunk: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(chunk.count)
        for byte in chunk { step(byte, into: &out) }
        return out
    }

    /// Release anything held back, so an ended stream never truncates real output.
    public mutating func flush() -> [UInt8] {
        defer { state = .idle(matched: []) }
        switch state {
        case .idle(let matched):                  return matched
        case .dropping, .droppingEsc,
             .droppingTitle, .droppingTitleEsc:   return []
        }
    }

    private mutating func step(_ byte: UInt8, into out: inout [UInt8]) {
        switch state {
        case .idle(let matched):
            var cand = matched
            cand.append(byte)
            if Self.openers.contains(cand) {
                state = .dropping(seen: 0)
                return
            }
            if Self.titleOpeners.contains(cand) {
                state = .droppingTitle(seen: 0)
                return
            }
            if Self.mouseEnables.contains(cand) {
                state = .idle(matched: [])
                return
            }
            if Self.extends(cand) {
                state = .idle(matched: cand)
                return
            }
            guard !matched.isEmpty else { out.append(byte); return }
            // Re-test the rest from scratch, so a match inside a false start still fires.
            out.append(matched[0])
            state = .idle(matched: [])
            for b in matched.dropFirst() { step(b, into: &out) }
            step(byte, into: &out)

        case .dropping(let seen):
            if byte == Self.bel || byte == Self.st8 || seen + 1 >= Self.clipboardCap { state = .idle(matched: []) }
            else if byte == Self.esc { state = .droppingEsc }
            else { state = .dropping(seen: seen + 1) }

        case .droppingEsc:
            state = .idle(matched: [])
            // ESC without a backslash aborts the sequence the way a terminal would, and begins anew.
            if byte != Self.backslash {
                step(Self.esc, into: &out)
                step(byte, into: &out)
            }

        case .droppingTitle(let seen):
            if byte == Self.bel || seen + 1 >= Self.titleCap { state = .idle(matched: []) }
            else if byte == Self.esc { state = .droppingTitleEsc }
            else { state = .droppingTitle(seen: seen + 1) }

        case .droppingTitleEsc:
            state = .idle(matched: [])
            if byte != Self.backslash {
                step(Self.esc, into: &out)
                step(byte, into: &out)
            }
        }
    }
}
