import XCTest
@testable import EmailJunkie

final class RFC822MessageTests: XCTestCase {

    private let date = Date(timeIntervalSince1970: 1_752_000_000) // fixed

    private func message(
        subject: String = "Re: Lunch?",
        body: String = "Sounds good!",
        inReplyTo: String? = "<orig@example.com>"
    ) -> OutgoingMessage {
        OutgoingMessage(
            from: "me@gmail.com",
            to: ["alice@example.com"],
            subject: subject,
            body: body,
            date: date,
            messageID: "<new-id@gmail.com>",
            inReplyTo: inReplyTo,
            references: [inReplyTo].compactMap { $0 }
        )
    }

    private func string(_ message: OutgoingMessage) -> String {
        String(data: message.rfc822(), encoding: .utf8) ?? ""
    }

    func testBuildsHeadersAndThreadingReferences() {
        let text = string(message())
        XCTAssertTrue(text.contains("From: me@gmail.com\r\n"))
        XCTAssertTrue(text.contains("To: alice@example.com\r\n"))
        XCTAssertTrue(text.contains("Subject: Re: Lunch?\r\n"))
        XCTAssertTrue(text.contains("Message-ID: <new-id@gmail.com>\r\n"))
        XCTAssertTrue(text.contains("In-Reply-To: <orig@example.com>\r\n"))
        XCTAssertTrue(text.contains("References: <orig@example.com>\r\n"))
        XCTAssertTrue(text.contains("Content-Transfer-Encoding: base64\r\n"))
    }

    func testOmitsThreadingHeadersWhenNoSourceID() {
        let text = string(message(inReplyTo: nil))
        XCTAssertFalse(text.contains("In-Reply-To:"))
        XCTAssertFalse(text.contains("References:"))
    }

    func testHeadersAndBodySeparatedByBlankLineAndBodyIsBase64() {
        let text = string(message(body: "Sounds good!"))
        let parts = text.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2, "exactly one header/body separator")
        let encodedBody = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = Data(base64Encoded: encodedBody).flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(decoded, "Sounds good!")
    }

    func testNonASCIISubjectIsRFC2047Encoded() {
        let text = string(message(subject: "Re: Café ☕"))
        XCTAssertTrue(text.contains("Subject: =?UTF-8?B?"), "got: \(text)")
        // The raw unicode must not appear unencoded in the headers.
        XCTAssertFalse(text.contains("Subject: Re: Café"))
    }

    func testDateIsRFC822Formatted() {
        XCTAssertEqual(OutgoingMessage.rfc822Date(date), "Tue, 08 Jul 2025 18:40:00 +0000")
    }
}
