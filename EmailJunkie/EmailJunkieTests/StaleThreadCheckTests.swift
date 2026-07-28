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

    private func message(
        id: UInt32,
        subject: String,
        from: MailAddress? = MailAddress(email: "alice@x.com"),
        to: [MailAddress] = [],
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 1,
            from: from,
            to: to,
            subject: subject,
            date: "",
            inReplyTo: inReplyTo,
            messageID: messageID
        )
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

    func testBlankSubjectStillDetectsThreadConflicts() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5, subject: "Re:"),
            threadMessages: [message(id: 5, subject: ""), message(id: 8, subject: "Re:")],
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
            sentReplies: [message(
                id: 2,
                subject: "Re: Lunch?",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "alice@x.com")]
            )]
        )
        XCTAssertEqual(verdict, .stale(.alreadyReplied))
    }

    func testSourceMissingTakesPrecedenceOverAlreadyReplied() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [],
            threadTruncated: false,
            sentReplies: [message(
                id: 2,
                subject: "Re: Lunch?",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "alice@x.com")]
            )]
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

    func testSameSubjectDifferentConversationIsIgnored() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5, subject: "Status update"),
            threadMessages: [
                message(id: 5, subject: "Status update"),
                message(id: 20, subject: "Re: Status update", from: MailAddress(email: "mallory@x.com"))
            ],
            threadTruncated: false,
            sentReplies: [message(
                id: 30,
                subject: "Re: Status update",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "mallory@x.com")]
            )]
        )
        XCTAssertEqual(verdict, .fresh)
    }

    func testDirectThreadLinkMatchesDifferentParticipant() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [
                message(id: 5, subject: "Lunch?"),
                message(
                    id: 9,
                    subject: "Re: Lunch?",
                    from: MailAddress(email: "carol@x.com"),
                    inReplyTo: "<orig@x.com>"
                )
            ],
            threadTruncated: false,
            sentReplies: []
        )
        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
    }

    func testIndirectThreadLinkMatchesNewParticipantReply() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [
                message(id: 3, subject: "Re: Lunch?", from: MailAddress(email: "bob@x.com"), messageID: "<bob@x.com>"),
                message(
                    id: 5,
                    subject: "Lunch?",
                    from: MailAddress(email: "alice@x.com"),
                    inReplyTo: "<bob@x.com>",
                    messageID: "<orig@x.com>"
                ),
                message(
                    id: 9,
                    subject: "Re: Lunch?",
                    from: MailAddress(email: "carol@x.com"),
                    inReplyTo: "<bob@x.com>",
                    messageID: "<carol@x.com>"
                )
            ],
            threadTruncated: false,
            sentReplies: []
        )
        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
    }

    func testSentReplyToKnownIntermediateMessageCountsAsAlreadyReplied() {
        let verdict = StaleThreadCheck.verdict(
            draft: draft(id: 5),
            threadMessages: [
                message(id: 3, subject: "Re: Lunch?", from: MailAddress(email: "bob@x.com"), messageID: "<bob@x.com>"),
                message(
                    id: 5,
                    subject: "Lunch?",
                    from: MailAddress(email: "alice@x.com"),
                    inReplyTo: "<bob@x.com>",
                    messageID: "<orig@x.com>"
                )
            ],
            threadTruncated: false,
            sentReplies: [
                message(
                    id: 2,
                    subject: "Re: Lunch?",
                    from: MailAddress(email: "me@gmail.com"),
                    to: [MailAddress(email: "bob@x.com")],
                    inReplyTo: "<bob@x.com>"
                )
            ]
        )
        XCTAssertEqual(verdict, .stale(.alreadyReplied))
    }

    func testRegenerationSourceUsesNewestRelatedMessage() throws {
        let source = try XCTUnwrap(StaleThreadCheck.regenerationSource(
            draft: draft(id: 5),
            threadMessages: [
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
                message(id: 20, subject: "Re: Lunch?", from: MailAddress(email: "mallory@x.com")),
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
            ]
        ))
        XCTAssertEqual(source.id, 9)
        XCTAssertEqual(source.messageID, "<new@x.com>")
    }
}
