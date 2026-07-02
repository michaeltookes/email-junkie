import XCTest
@testable import EmailJunkie

final class LoopbackRedirectListenerTests: XCTestCase {

    func testParsesCodeAndStateFromRequestLine() {
        let request = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let params = LoopbackRedirectListener.parseQuery(fromRequestLine: request)
        XCTAssertEqual(params["code"], "abc123")
        XCTAssertEqual(params["state"], "xyz")
    }

    func testParsesErrorRedirect() {
        let request = "GET /callback?error=access_denied&state=xyz HTTP/1.1\r\n\r\n"
        let params = LoopbackRedirectListener.parseQuery(fromRequestLine: request)
        XCTAssertEqual(params["error"], "access_denied")
    }

    func testReturnsEmptyForMalformedRequest() {
        XCTAssertTrue(LoopbackRedirectListener.parseQuery(fromRequestLine: "").isEmpty)
        XCTAssertTrue(LoopbackRedirectListener.parseQuery(fromRequestLine: "garbage").isEmpty)
    }

    func testPathWithoutQueryYieldsNoParams() {
        let request = "GET /favicon.ico HTTP/1.1\r\n\r\n"
        XCTAssertTrue(LoopbackRedirectListener.parseQuery(fromRequestLine: request).isEmpty)
    }
}
