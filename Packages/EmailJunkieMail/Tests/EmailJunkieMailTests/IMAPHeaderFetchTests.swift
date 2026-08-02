import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import EmailJunkieMail

/// Drives `IMAPHeaderFetchHandler` through the real IMAP decoder with an
/// `EmbeddedChannel`, feeding raw server responses — deterministic coverage of
/// the LOGIN → SELECT → UID FETCH (BODY.PEEK[HEADER.FIELDS (...)]) state machine
/// and the header parsing, no server.
final class IMAPHeaderFetchTests: XCTestCase {

    private func makeChannel(
        uid: UInt32 = 101,
        mailbox: String = "INBOX",
        expectedUIDValidity: UInt32? = nil
    ) throws -> (EmbeddedChannel, EventLoopFuture<MailHeaderFields>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: MailHeaderFields.self)
        let handler = IMAPHeaderFetchHandler(
            email: "me@gmail.com",
            password: "pw",
            mailboxName: mailbox,
            uid: uid,
            expectedUIDValidity: expectedUIDValidity,
            promise: promise
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])
        return (channel, promise.futureResult)
    }

    private func feed(_ channel: EmbeddedChannel, _ response: String) throws {
        try channel.writeInbound(ByteBuffer(string: response))
        while (try? channel.readOutbound(as: ByteBuffer.self)) != nil {}
    }

    private func headerSection(_ block: String) -> String {
        "* 1 FETCH (UID 101 BODY[HEADER.FIELDS (LIST-ID LIST-UNSUBSCRIBE PRECEDENCE "
            + "AUTO-SUBMITTED X-AUTO-RESPONSE-SUPPRESS CONTENT-TYPE)] {\(block.utf8.count)}\r\n\(block))\r\n"
    }

    func testParsesListAndPrecedenceHeaders() throws {
        let (channel, future) = try makeChannel()
        let block = "List-Id: Widgets <widgets.example.com>\r\n"
            + "List-Unsubscribe: <mailto:unsub@example.com>\r\n"
            + "Precedence: bulk\r\n\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* 3 EXISTS\r\n")
        try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")
        try feed(channel, headerSection(block))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(fields.listID, "Widgets <widgets.example.com>")
        XCTAssertEqual(fields.listUnsubscribe, "<mailto:unsub@example.com>")
        XCTAssertEqual(fields.precedence, "bulk")
        XCTAssertNil(fields.contentType)
        _ = try? channel.finish()
    }

    func testParsesCalendarContentTypeAndAutomationHeaders() throws {
        let (channel, future) = try makeChannel()
        let block = "Auto-Submitted: auto-generated\r\n"
            + "X-Auto-Response-Suppress: All\r\n"
            + "Content-Type: text/calendar; method=REQUEST; charset=UTF-8\r\n\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(fields.autoSubmitted, "auto-generated")
        XCTAssertEqual(fields.autoResponseSuppress, "All")
        XCTAssertEqual(fields.contentType, "text/calendar; method=REQUEST; charset=UTF-8")
        _ = try? channel.finish()
    }

    func testUnfoldsFoldedHeaderValues() throws {
        let (channel, future) = try makeChannel()
        // A List-Unsubscribe folded across two lines must reassemble intact.
        let block = "List-Unsubscribe: <mailto:unsub@example.com>,\r\n"
            + " <https://example.com/unsub>\r\n\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(
            fields.listUnsubscribe,
            "<mailto:unsub@example.com>, <https://example.com/unsub>"
        )
        _ = try? channel.finish()
    }

    func testFetchWithoutHeaderSectionReturnsEmptyFields() throws {
        // A plain personal message carries none of the requested headers; the
        // server returns an empty section, which is a valid reply-worthy result.
        let (channel, future) = try makeChannel()
        let block = "\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block))
        try feed(channel, "A3 OK FETCH completed\r\n")

        XCTAssertEqual(try future.wait(), MailHeaderFields())
        _ = try? channel.finish()
    }

    func testFetchOKWithNoBodySectionReturnsEmptyFields() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, "A3 OK FETCH completed\r\n")

        XCTAssertEqual(try future.wait(), MailHeaderFields())
        _ = try? channel.finish()
    }

    func testUIDValidityMismatchSurfacesCommandError() throws {
        let (channel, future) = try makeChannel(expectedUIDValidity: 123)

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* OK [UIDVALIDITY 456] UIDs valid\r\n")
        try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertEqual(
                error as? MailError,
                .commandFailed("The mailbox changed before the message headers were fetched.")
            )
        }
        _ = try? channel.finish()
    }

    func testLoginFailureSurfacesAuthenticationError() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .authenticationFailed = error as? MailError else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
        _ = try? channel.finish()
    }

    func testSelectFailureSurfacesCommandError() throws {
        let (channel, future) = try makeChannel(mailbox: "[Gmail]/Does Not Exist")

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 NO Unknown mailbox\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
        }
        _ = try? channel.finish()
    }
}
