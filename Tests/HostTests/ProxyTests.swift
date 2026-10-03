import Foundation
import Testing
@testable import Host

struct ProxyTests {
    private func request(method: String, path: String, body: Data = Data()) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: [:], body: body)
    }

    @Test func testBodylessProbesAreNotReported() {
        for method in ["GET", "HEAD", "OPTIONS", "head", "get"] {
            for path in ["/", "/?x=1", "/health", "/.well-known/x", "/favicon.ico"] {
                #expect(!Proxy.isNotableRefusal(request(method: method, path: path)),
                        Comment(rawValue: "\(method) \(path)"))
            }
        }
        #expect(Proxy(credentials: Credentials()).buildUpstreamRequest(request(method: "HEAD", path: "/")) == nil)
    }

    @Test func testActiveAttemptsAreReported() {
        #expect(Proxy.isNotableRefusal(request(method: "POST", path: "/v1/evil")))
        #expect(Proxy.isNotableRefusal(request(method: "DELETE", path: "/")))
        #expect(Proxy.isNotableRefusal(request(method: "GET", path: "/", body: Data("x".utf8))))
    }
}
