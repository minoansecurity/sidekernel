import Foundation

/// The wire contract; mirrors agent/src/contract.rs.
public enum Contract {
    public static let controlPort: UInt32 = 4243   // guest listens, host dials
    public static let servicePort: UInt32 = 4244   // host listens, guest dials
    public static let relayPort: UInt16 = 4242     // guest loopback TCP: the CLIs' *_BASE_URL

    // Checked against the declared length before any copy.
    public static let maxControlFrame = 1_048_576
    public static let maxCtlReplyFrame = 67_112_960
    public static let maxAdoptBlob = 65_536
    public static let maxCtlPayload = 4_096
    public static let maxCopyPayload = 262_144
    public static let maxCtlReplyPayload = 67_108_864
    public static let nonceLength = 32

    /// Proves a guest dial belongs to this exec.
    public static func randomNonce() -> String {
        let hex = Array("0123456789abcdef")
        return String((0..<nonceLength).map { _ in hex.randomElement()! })
    }

    public static let cmdlineOverlay = "sk_boot=overlay"
    public static let cmdlineNetwait = "sk_netwait"
    public static let labelBase = "sk-base"
    public static let labelPersonal = "sk-personal"
    public static let labelStaging = "sk-staging"
    public static let ext4MagicOffset: UInt64 = 0x438
    public static let ext4LabelOffset: UInt64 = 0x478
    public static let stagingMount = "/staging"
    public static let degradedMarker = "/run/sk-degraded"
    public static let dropsDir = "/root/.sk-drops"
    public static let tagProject = "project"
    public static let tagSeed = "seed"
    public static let projectMount = "/run/sk-project"
    public static let seedMount = "/run/sk-seed"
    public static let guestConfigDir = "/run/sk-project/claude"
    public static let guestCodexDir = "/run/sk-project/codex"
    public static let codexProxyPath = "/codex"
    public static let credentialFile = "/run/sk-project/claude/.credentials.json"

    /// The proxy swaps this for the real key, so the guest never holds one.
    public static let placeholderKey = "sk-sidekernel-proxy-placeholder"

    /// The same stand-in as a credential file, written over an adopted login.
    public static let placeholderBlob = Data(#"""
    {"claudeAiOauth":{"accessToken":"sk-sidekernel-proxy-placeholder","refreshToken":"sk-sidekernel-proxy-placeholder","expiresAt":4102444800000,"scopes":["user:inference","user:profile"]}}
    """#.utf8)
}

public enum StdioStream: UInt8, Sendable { case stdin = 0, stdout = 1 }
public enum CtlVerb: UInt8, Sendable { case save = 1, clip = 2, drop = 3, net = 4, copy = 5 }
public enum CtlStatus: UInt8, Sendable { case ok = 0, deny = 1, err = 2 }

public struct FrameDecodeError: Error, Equatable {
    public let reason: String
}

/// Each frame is `[u32 BE length][u8 tag][body]`.
public enum Frame: Equatable, Sendable {
    case helloExec(networkOn: Bool)
    case helloTunnel(port: UInt16)
    case helloNetChanged(on: Bool)
    case exec(nonce: String, workdir: String, argv: [String], env: [String], cols: UInt16, rows: UInt16)
    case resize(cols: UInt16, rows: UInt16)
    case started
    case error(reason: String)
    case exited(code: Int32)
    case helloStdio(which: StdioStream, nonce: String)
    case helloPortEvents
    case helloProxy
    case adopt(blob: [UInt8])
    case ctl(verb: CtlVerb, payload: [UInt8])
    case portEvent(port: UInt16, open: Bool)
    /// A ctl verb's answer. An allowed drop streams instead: an ok `dir`/`file` header, its bytes as
    /// ok payload chunks, then an empty chunk, or an err reply if the copy fails partway.
    case ctlReply(status: CtlStatus, message: String, payload: [UInt8])

    /// Nil if a string or list outgrows its u16 length.
    public func encode() -> [UInt8]? {
        var e = Enc()
        switch self {
        case .helloExec(let on): e.tag(0x01); e.flag(on)
        case .helloTunnel(let port): e.tag(0x02); e.u16(port)
        case .helloNetChanged(let on): e.tag(0x03); e.flag(on)
        case .exec(let nonce, let workdir, let argv, let env, let cols, let rows):
            e.tag(0x05); e.str(nonce); e.str(workdir); e.list(argv); e.list(env)
            e.u16(cols); e.u16(rows)
        case .resize(let cols, let rows): e.tag(0x06); e.u16(cols); e.u16(rows)
        case .started: e.tag(0x07)
        case .error(let reason): e.tag(0x08); e.str(reason)
        case .exited(let code): e.tag(0x09); e.u32(UInt32(bitPattern: code))
        case .helloStdio(let which, let nonce): e.tag(0x11); e.u8(which.rawValue); e.str(nonce)
        case .helloPortEvents: e.tag(0x12)
        case .helloProxy: e.tag(0x13)
        case .adopt(let blob): e.tag(0x14); e.bytes(blob)
        case .ctl(let verb, let payload): e.tag(0x15); e.u8(verb.rawValue); e.bytes(payload)
        case .portEvent(let port, let open): e.tag(0x16); e.u16(port); e.flag(open)
        case .ctlReply(let status, let message, let payload):
            e.tag(0x17); e.u8(status.rawValue); e.str(message); e.bytes(payload)
        }
        if e.overflow { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(e.out.count + 4)
        let length = UInt32(e.out.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(contentsOf: e.out)
        return out
    }

    public static func decode(_ bytes: [UInt8]) throws -> Frame {
        var d = Dec(bytes[...])
        guard let declared = try? d.u32() else { throw FrameDecodeError(reason: "incomplete length prefix") }
        guard declared > 0 else { throw FrameDecodeError(reason: "frame length must be at least 1") }
        guard let payload = try? d.take(Int(declared)) else {
            throw FrameDecodeError(reason: "declared length exceeds available bytes")
        }
        guard d.finished else { throw FrameDecodeError(reason: "trailing bytes after frame") }
        let frame = try decodePayload(payload)
        let cap: Int
        if case .ctlReply = frame { cap = Contract.maxCtlReplyFrame } else { cap = Contract.maxControlFrame }
        guard Int(declared) <= cap else { throw FrameDecodeError(reason: "frame exceeds cap") }
        return frame
    }

    public static func decodePayload(_ payload: ArraySlice<UInt8>) throws -> Frame {
        var d = Dec(payload)
        let frame: Frame
        switch try d.u8() {
        case 0x01: frame = .helloExec(networkOn: try d.flag())
        case 0x02: frame = .helloTunnel(port: try d.u16())
        case 0x03: frame = .helloNetChanged(on: try d.flag())
        case 0x05: frame = .exec(nonce: try d.nonce(), workdir: try d.str(),
                                 argv: try d.listMinOne(), env: try d.list(),
                                 cols: try d.u16(), rows: try d.u16())
        case 0x06: frame = .resize(cols: try d.u16(), rows: try d.u16())
        case 0x07: frame = .started
        case 0x08: frame = .error(reason: try d.str())
        case 0x09: frame = .exited(code: Int32(bitPattern: try d.u32()))
        case 0x11:
            guard let which = StdioStream(rawValue: try d.u8()) else {
                throw FrameDecodeError(reason: "which must be 0 or 1")
            }
            frame = .helloStdio(which: which, nonce: try d.nonce())
        case 0x12: frame = .helloPortEvents
        case 0x13: frame = .helloProxy
        case 0x14: frame = .adopt(blob: try d.bytes(cap: Contract.maxAdoptBlob))
        case 0x15:
            guard let verb = CtlVerb(rawValue: try d.u8()) else {
                throw FrameDecodeError(reason: "unknown ctl verb")
            }
            let cap = verb == .copy ? Contract.maxCopyPayload : Contract.maxCtlPayload
            frame = .ctl(verb: verb, payload: try d.bytes(cap: cap))
        case 0x16: frame = .portEvent(port: try d.u16(), open: try d.flag())
        case 0x17:
            guard let status = CtlStatus(rawValue: try d.u8()) else {
                throw FrameDecodeError(reason: "unknown ctl reply status")
            }
            frame = .ctlReply(status: status, message: try d.str(),
                              payload: try d.bytes(cap: Contract.maxCtlReplyPayload))
        default: throw FrameDecodeError(reason: "unknown tag")
        }
        guard d.finished else { throw FrameDecodeError(reason: "body not fully consumed") }
        return frame
    }

    public var name: String {
        switch self {
        case .helloExec: "HelloExec"
        case .helloTunnel: "HelloTunnel"
        case .helloNetChanged: "HelloNetChanged"
        case .exec: "Exec"
        case .resize: "Resize"
        case .started: "Started"
        case .error: "Error"
        case .exited: "Exited"
        case .helloStdio: "HelloStdio"
        case .helloPortEvents: "HelloPortEvents"
        case .helloProxy: "HelloProxy"
        case .adopt: "Adopt"
        case .ctl: "Ctl"
        case .portEvent: "PortEvent"
        case .ctlReply: "CtlReply"
        }
    }
}

private struct Enc {
    var out: [UInt8] = []
    var overflow = false
    mutating func tag(_ t: UInt8) { out.append(t) }
    mutating func u8(_ v: UInt8) { out.append(v) }
    mutating func u16(_ v: UInt16) { out.append(UInt8(truncatingIfNeeded: v >> 8)); out.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(truncatingIfNeeded: v >> 16)); u16(UInt16(truncatingIfNeeded: v)) }
    mutating func flag(_ v: Bool) { out.append(v ? 1 : 0) }
    mutating func str(_ s: String) { let b = Array(s.utf8); count(b.count); out.append(contentsOf: b) }
    mutating func bytes(_ b: [UInt8]) { u32(UInt32(b.count)); out.append(contentsOf: b) }
    mutating func list(_ items: [String]) { count(items.count); for item in items { str(item) } }
    private mutating func count(_ n: Int) {
        guard let n16 = UInt16(exactly: n) else { overflow = true; return }
        u16(n16)
    }
}

/// Bounds-checked, so hostile bytes throw instead of crashing.
private struct Dec {
    private let bytes: ArraySlice<UInt8>
    private var pos: Int

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes; pos = bytes.startIndex }

    var finished: Bool { pos == bytes.endIndex }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, bytes.endIndex - pos >= n else { throw FrameDecodeError(reason: "truncated") }
        defer { pos += n }
        return bytes[pos ..< pos + n]
    }

    mutating func u8() throws -> UInt8 {
        guard let byte = try take(1).first else { throw FrameDecodeError(reason: "truncated") }
        return byte
    }

    mutating func u16() throws -> UInt16 {
        let hi = try u8(), lo = try u8()
        return UInt16(hi) << 8 | UInt16(lo)
    }

    mutating func u32() throws -> UInt32 {
        let hi = try u16(), lo = try u16()
        return UInt32(hi) << 16 | UInt32(lo)
    }

    mutating func flag() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw FrameDecodeError(reason: "bool must be 0 or 1")
        }
    }

    mutating func str() throws -> String {
        let raw = try take(Int(try u16()))
        guard let s = String(bytes: raw, encoding: .utf8) else {
            throw FrameDecodeError(reason: "str must be valid UTF-8")
        }
        return s
    }

    mutating func nonce() throws -> String {
        let s = try str()
        guard s.utf8.count == Contract.nonceLength else {
            throw FrameDecodeError(reason: "nonce must be exactly 32 bytes")
        }
        return s
    }

    mutating func bytes(cap: Int) throws -> [UInt8] {
        let declared = try u32()
        guard Int(declared) <= cap else { throw FrameDecodeError(reason: "field exceeds cap") }
        return Array(try take(Int(declared)))
    }

    mutating func list() throws -> [String] {
        let count = try u16()
        var items: [String] = []
        items.reserveCapacity(Int(count))
        for _ in 0 ..< count { items.append(try str()) }
        return items
    }

    mutating func listMinOne() throws -> [String] {
        let items = try list()
        guard !items.isEmpty else { throw FrameDecodeError(reason: "argv must not be empty") }
        return items
    }
}
