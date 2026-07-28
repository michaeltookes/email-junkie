import EmailJunkieMail
import XCTest
@testable import EmailJunkie

/// Tests for the pure stale-thread evaluator (item 12). These are the load-
/// bearing detection rules — a stale send is especially bad in auto-send mode —
/// so they are exercised here against representative thread-change cases with no
/// IMAP involved.
final class StaleThreadCheckTests: XCTestCase {

    private func draft(id: UInt32 = 5, subject: String = "Lunch?") -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 1,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: subject,
            sourceFrom: MailAddress(name: "Alice", email: "alice@x.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@x.com>",
            replySubject: "Re: \(subject)",
            body: "Sounds good!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func message(id: UInt32, subject: String) -> MailMessage {
        MailMessage(id: id, uidValidity: 1, from: MailAddress(email: "x@x.com"), subject: subject, date: "")
    }

    // MARK: - Subject normalization

    func testNormalizedSubjectKeyStripsReplyAndForwardPrefixes() {
        XCTAssertEqual(StaleThreadCheck.normalizedSubjectKey("Re: Hi"), "hi")
        XCTAssertEqual(StaleThreadCheck.normalizedSubjectKey("RE: FWD:  Hi there "), "hi there")
        XCTAssertEqual(StaleThreadCheck.normalizedSubjectKey("Fw: Lunch?"), "lunch?")
        XCTAssertEqual(StaleThreadCheck.normalizedSubjectKey("Plain"), "plain")
    }

    // MARK: - Verdicts

    func testFreshWhenSourcePresentAndNothingNewer() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [message(id: 5, subject: "Lunch?")],
            threadTruncated: false,
            sentReplies: []
        )
        XCTAssertEqual(verdict, .fresh)
    }

    func testSourceMissingWhenThreadFullySeenWithoutSource() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [message(id: 9, subject: "Different topic")],
            threadTruncated: false,
            sentReplies: []
        )
        XCTAssertEqual(verdict, .stale(.sourceMissing))
    }

    func testSourceMissingNotClaimedWhenSearchTruncated() {
        // Source absent but the search had more pages — inconclusive for "gone",
        // and a higher-UID message means a newer reply arrived.
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [message(id: 10, subject: "Re: Lunch?")],
            threadTruncated: true,
            sentReplies: []
        )
        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
    }

    func testNewerReplyWhenHigherUIDInThread() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [message(id: 5, subject: "Lunch?"), message(id: 8, subject: "Re: Lunch?")],
            threadTruncated: false,
            sentReplies: []
        )
        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
    }

    func testAlreadyRepliedTakesPrecedenceOverNewerReply() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [message(id: 5, subject: "Lunch?"), message(id: 8, subject: "Re: Lunch?")],
            threadTruncated: false,
            sentReplies: [message(id: 2, subject: "Re: Lunch?")]
        )
        XCTAssertEqual(verdict, .stale(.alreadyReplied))
    }

    func testSourceMissingTakesPrecedenceOverAlreadyReplied() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [],
            threadTruncated: false,
            sentReplies: [message(id: 2, subject: "Re: Lunch?")]
        )
        XCTAssertEqual(verdict, .stale(.sourceMissing))
    }

    func testUnrelatedSubjectsAreIgnored() {
        // A higher UID in a different thread must not be read as a newer reply.
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [message(id: 5, subject: "Lunch?"), message(id: 20, subject: "Unrelated blast")],
            threadTruncated: false,
            sentReplies: [message(id: 30, subject: "Newsletter")]
        )
        XCTAssertEqual(verdict, .fresh)
    }
}
