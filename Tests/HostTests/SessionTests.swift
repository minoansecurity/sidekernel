import Darwin
import Foundation
import Testing
@testable import Host

struct SessionTests {
    @Test func pastedTextCannotGrantClipboardAccess() {
        let start = Array("\u{1B}[200~".utf8), end = Array("\u{1B}[201~".utf8)
        let text = Array("literal \u{16} \u{1B}[118;5u \u{1B}[118;5:1u \u{1B}[27;5;118~".utf8)
        let payload = start + text + end
        for split in 0...payload.count {
            let grant = ClipboardGrant()
            grant.noteInput(payload[..<split])
            grant.noteInput(payload[split...])
            #expect(!grant.isLive)
            grant.noteInput([ClipboardGrant.pasteByte][...])
            #expect(grant.isLive)
        }
        let grant = ClipboardGrant()
        for byte in payload {
            grant.noteInput([byte][...])
            #expect(!grant.isLive)
        }
    }

    @Test func clipboardGrantRecognizesSplitCodexKeysWithoutExtendingOnOrdinaryInput() {
        let keys = ["\u{16}", "\u{1B}[118;5u", "\u{1B}[118;5:1u", "\u{1B}[118;5:2u", "\u{1B}[27;5;118~"]
        for key in keys {
            let bytes = Array(key.utf8)
            for split in 0...bytes.count {
                var now = Date(timeIntervalSince1970: 100)
                let grant = ClipboardGrant(window: 10, now: { now })
                grant.noteInput(bytes[..<split])
                grant.noteInput(bytes[split...])
                #expect(grant.isLive)
                now = now.addingTimeInterval(11)
                grant.noteInput(Array("ordinary input".utf8)[...])
                #expect(!grant.isLive)
            }
        }
        for text in ["\u{1B}[118;5:3u", "\u{1B}[118;1u", "\u{1B}[117;5u", "\u{1B}[27;1;118~"] {
            let grant = ClipboardGrant()
            grant.noteInput(Array(text.utf8)[...])
            #expect(!grant.isLive)
        }
    }

    @Test func pipedInputPreservesBytesAndHalfClosesAtEOF() throws {
        let input = Pipe()
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { sockets.forEach { close($0) } }
        FDIO.setReadTimeout(sockets[1], seconds: 2)
        let destination = sockets[0]
        let done = DispatchSemaphore(value: 0)
        Thread {
            Session.pumpOperatorInput(from: input.fileHandleForReading.fileDescriptor, to: destination, grant: nil)
            done.signal()
        }.start()
        let payload = Array("line one\nline two\r\n\u{0}\u{04}no trailing newline".utf8)
        try input.fileHandleForWriting.write(contentsOf: Data(payload))
        try input.fileHandleForWriting.close()
        #expect(FDIO.readFull(sockets[1], count: payload.count) == payload)
        #expect(done.wait(timeout: .now() + 2) == .success)
        var byte: UInt8 = 0
        #expect(read(sockets[1], &byte, 1) == 0, Comment(rawValue: "the guest must receive EOF, not wait indefinitely"))
        #expect(FDIO.writeAll(sockets[1], [42]), Comment(rawValue: "input EOF must not close the return direction"))
        #expect(FDIO.readFull(sockets[0], count: 1) == [42])
    }

    @Test func execWireDistinguishesTerminalAndByteStreams() throws {
        for tty in [true, false] {
            let frame = Frame.exec(nonce: String(repeating: "0", count: 32), workdir: "/workspace",
                                   argv: ["cat"], env: [], tty: tty, cols: 80, rows: 24)
            let bytes = try #require(frame.encode())
            let body: [UInt8] = [5, 0, 32] + Array(String(repeating: "0", count: 32).utf8)
                + [0, 10] + Array("/workspace".utf8) + [0, 1, 0, 3] + Array("cat".utf8)
                + [0, 0, tty ? 1 : 0, 0, 80, 0, 24]
            #expect(bytes == [0, 0, 0, 61] + body)
            #expect(try Frame.decode(bytes) == frame)
            var invalid = bytes
            invalid[invalid.count - 5] = 2
            #expect(throws: FrameDecodeError.self) { try Frame.decode(invalid) }
        }
    }

    @Test func stderrHasItsOwnAuthenticatedStream() throws {
        let nonce = String(repeating: "0", count: 32)
        let frame = Frame.helloStdio(which: .stderr, nonce: nonce)
        let bytes = try #require(frame.encode())
        #expect(bytes == [0, 0, 0, 36, 17, 2, 0, 32] + Array(nonce.utf8))
        #expect(try Frame.decode(bytes) == frame)
    }
}
