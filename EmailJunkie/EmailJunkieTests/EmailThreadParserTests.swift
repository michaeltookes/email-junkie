import XCTest
@testable import EmailJunkie

final class EmailThreadParserTests: XCTestCase {

    // MARK: - split

    func testMessageWithoutQuotesIsAllLatest() {
        let thread = EmailThreadParser.split("Are you free for lunch Thursday at noon?")
        XCTAssertEqual(thread.latest, "Are you free for lunch Thursday at noon?")
        XCTAssertEqual(thread.quotedHistory, "")
    }

    func testSplitsAtGmailAttributionLine() {
        let body = """
        Yes, Thursday works great.

        On Mon, Jul 21, 2026 at 9:00 AM Alice <alice@example.com> wrote:
        > Are you free for lunch Thursday?
        > — Alice
        """
        let thread = EmailThreadParser.split(body)
        XCTAssertEqual(thread.latest, "Yes, Thursday works great.\n")
        XCTAssertTrue(thread.quotedHistory.hasPrefix("On Mon, Jul 21, 2026"))
        XCTAssertTrue(thread.quotedHistory.contains("> Are you free for lunch Thursday?"))
    }

    func testSplitsAtOutlookOriginalMessageSeparator() {
        let body = """
        Sounds good.

        -----Original Message-----
        From: Bob
        Subject: Re: Proposal
        The proposal looks fine.
        """
        let thread = EmailThreadParser.split(body)
        XCTAssertEqual(thread.latest, "Sounds good.\n")
        XCTAssertTrue(thread.quotedHistory.hasPrefix("-----Original Message-----"))
    }

    func testSplitsAtLeadingQuoteMarker() {
        let body = """
        Agreed.
        > previous line one
        > previous line two
        """
        let thread = EmailThreadParser.split(body)
        XCTAssertEqual(thread.latest, "Agreed.")
        XCTAssertEqual(thread.quotedHistory, "> previous line one\n> previous line two")
    }

    func testMessageThatIsEntirelyQuotedHasEmptyLatest() {
        let body = "> only quoted content here"
        let thread = EmailThreadParser.split(body)
        XCTAssertEqual(thread.latest, "")
        XCTAssertEqual(thread.quotedHistory, "> only quoted content here")
    }

    func testAttributionMustEndWithWrote() {
        // A line that starts with "On" but is ordinary prose is not a marker.
        let body = "On second thought, let's meet Friday instead."
        let thread = EmailThreadParser.split(body)
        XCTAssertEqual(thread.latest, "On second thought, let's meet Friday instead.")
        XCTAssertEqual(thread.quotedHistory, "")
    }

    // MARK: - readableHistory

    func testReadableHistoryStripsQuoteMarkers() {
        let quoted = """
        On Mon Alice wrote:
        > line one
        >> nested line
        > line three
        """
        let readable = EmailThreadParser.readableHistory(fromQuoted: quoted, maxChars: 1000)
        XCTAssertEqual(readable, "On Mon Alice wrote:\nline one\nnested line\nline three")
    }

    func testReadableHistoryIsEmptyWhenNoHistory() {
        XCTAssertEqual(EmailThreadParser.readableHistory(fromQuoted: "", maxChars: 1000), "")
    }

    func testReadableHistoryIsCappedAtMaxChars() {
        let quoted = "> " + String(repeating: "z", count: 500)
        let readable = EmailThreadParser.readableHistory(fromQuoted: quoted, maxChars: 40)
        XCTAssertEqual(readable.count, 40)
    }
}
