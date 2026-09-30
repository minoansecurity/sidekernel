import Darwin
import Foundation
import Testing
@testable import Host

struct SessionTests {
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
