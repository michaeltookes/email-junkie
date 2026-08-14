import SentwiseMail
import Foundation
import XCTest
@testable import Sentwise

/// A mail provider whose `searchMessages` returns configurable results per
/// mailbox, so the stale-thread re-check can be driven without a real server.
final class SearchStubMailProvider: MailProvider, @unchecked Sendable {
    var threadResult: MailSearchResult
    var sentResult: MailSearchResult
    var searchError: MailError?
    var threadSearchError: MailError?
    var sentSearchError: MailError?
    var pageResults: [Mailbox: [Int: MailSearchResult]] = [:]
    var searchHandler: ((Mailbox, MailSearchCriteria, Int, Int) -> MailSearchResult?)?
    var bodyResult: Result<Data, MailError> = .success(Data("Please approve the budget.".utf8))
    private(set) var sendCount = 0
    private(set) var appendCount = 0
    private(set) var lastBodyUID: UInt32?
    private(set) var lastBodyMailbox: Mailbox?
    private(set) var lastExpectedUIDValidity: UInt32?
    private(set) var searchRequests: [(mailbox: Mailbox, criteria: MailSearchCriteria, offset: Int, limit: Int)] = []
    private(set) var pageRequests: [(mailbox: Mailbox, offset: Int, limit: Int, snapshotMessageCount: Int?)] = []

    init(
        threadResult: MailSearchResult = .empty(offset: 0),
        sentResult: MailSearchResult = .empty(offset: 0)
    ) {
        self.threadResult = threadResult
        self.sentResult = sentResult
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        lastBodyUID = uid
        lastBodyMailbox = mailbox
        lastExpectedUIDValidity = expectedUIDValidity
        return try bodyResult.get()
    }

    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        if let searchError { throw searchError }
        searchRequests.append((mailbox, criteria, offset, limit))
        if let handled = searchHandler?(mailbox, criteria, offset, limit) {
            return handled
        }
        if !criteria.headers.isEmpty {
            return .empty(offset: offset)
        }
        if mailbox == .sent {
            if let sentSearchError { throw sentSearchError }
            return pageResults[mailbox]?[offset] ?? sentResult
        }
        if let threadSearchError { throw threadSearchError }
        return pageResults[mailbox]?[offset] ?? threadResult
    }

    func fetchMessagePage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        offset: Int,
        limit: Int,
        snapshotMessageCount: Int?
    ) async throws -> MailSearchResult {
        if let searchError { throw searchError }
        pageRequests.append((mailbox, offset, limit, snapshotMessageCount))
        searchRequests.append((mailbox, MailSearchCriteria(), offset, limit))
        if mailbox == .sent {
            if let sentSearchError { throw sentSearchError }
            return pageResults[mailbox]?[offset] ?? sentResult
        }
        if let threadSearchError { throw threadSearchError }
        return pageResults[mailbox]?[offset] ?? threadResult
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws { appendCount += 1 }

    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws { sendCount += 1 }
}

@MainActor
final class AppStateStaleThreadReviewFeedbackTests: XCTestCase {
    private let replacementApprovedMessage = "That replacement draft was already approved. "
        + "The original draft is still queued for review."

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
        uidValidity: UInt32? = 1,
        from: MailAddress? = MailAddress(email: "alice@x.com"),
        to: [MailAddress] = [],
        date: String = "",
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: from,
            to: to,
            subject: subject,
            date: date,
            inReplyTo: inReplyTo,
            messageID: messageID
        )
    }

    private func result(_ messages: [MailMessage], hasMore: Bool = false) -> MailSearchResult {
        MailSearchResult(messages: messages, totalMatches: messages.count, offset: 0, hasMore: hasMore)
    }

    private func hasHeader(_ criteria: MailSearchCriteria, field: String, value: String) -> Bool {
        criteria.headers.contains(MailHeaderSearch(field: field, value: value))
    }

    private func makeAppState(
        provider: MailProvider,
        llmText: String = "Fresh reply."
    ) -> AppState {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        ))
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: llmText)))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        return appState
    }

    func testVerdictPaginatesBlankSubjectThreadUntilSourcePage() async {
        let firstPage = (0..<50).map {
            message(
                id: UInt32(200 - $0),
                subject: "Other \($0)",
                from: MailAddress(email: "nobody\($0)@x.com")
            )
        }
        let provider = SearchStubMailProvider()
        provider.pageResults[.inbox] = [
            0: MailSearchResult(messages: firstPage, totalMatches: 52, offset: 0, hasMore: true),
            50: MailSearchResult(messages: [
                message(id: 9, subject: "Re:", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>"),
                message(id: 5, subject: "", messageID: "<orig@x.com>")
            ], totalMatches: 52, offset: 50, hasMore: false)
        ]
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(
            for: draft(subject: "Re:"),
            credentials: appState.mailCredentials
        )

        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
        let inboxRequests = provider.pageRequests.filter { $0.mailbox == .inbox }
        XCTAssertEqual(inboxRequests.map { $0.offset }, [0, 50])
        XCTAssertNil(inboxRequests.first?.snapshotMessageCount)
        XCTAssertEqual(inboxRequests.last?.snapshotMessageCount, 52)
    }

    func testVerdictPaginatesBlankSubjectSentUntilReplyFound() async {
        let firstSentPage = (0..<50).map {
            message(
                id: UInt32(300 - $0),
                subject: "Other \($0)",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "nobody\($0)@x.com")],
                date: "Tue, 14 Nov 2023 23:00:00 +0000"
            )
        }
        let provider = SearchStubMailProvider()
        provider.pageResults[.inbox] = [
            0: MailSearchResult(
                messages: [message(id: 5, subject: "", messageID: "<orig@x.com>")],
                totalMatches: 1,
                offset: 0,
                hasMore: false
            )
        ]
        provider.pageResults[.sent] = [
            0: MailSearchResult(messages: firstSentPage, totalMatches: 51, offset: 0, hasMore: true),
            50: MailSearchResult(messages: [message(
                id: 2,
                subject: "Re:",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "alice@x.com")],
                date: "Tue, 14 Nov 2023 23:00:00 +0000"
            )], totalMatches: 51, offset: 50, hasMore: false)
        ]
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(
            for: draft(subject: "Re:"),
            credentials: appState.mailCredentials
        )

        XCTAssertEqual(verdict, .stale(.alreadyReplied))
        let sentRequests = provider.pageRequests.filter { $0.mailbox == .sent }
        XCTAssertEqual(sentRequests.map { $0.offset }, [0, 50])
        XCTAssertNil(sentRequests.first?.snapshotMessageCount)
        XCTAssertEqual(sentRequests.last?.snapshotMessageCount, 51)
    }

    func testVerdictPaginatesSubjectThreadUntilSourcePage() async {
        let firstPage = (0..<50).map {
            message(
                id: UInt32(200 - $0),
                subject: "Lunch?",
                from: MailAddress(email: "nobody\($0)@x.com"),
                messageID: "<unrelated-\($0)@x.com>"
            )
        }
        let provider = SearchStubMailProvider()
        provider.pageResults[.inbox] = [
            0: MailSearchResult(messages: firstPage, totalMatches: 52, offset: 0, hasMore: true),
            50: MailSearchResult(messages: [
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>"),
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>")
            ], totalMatches: 52, offset: 50, hasMore: false)
        ]
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(
            for: draft(),
            credentials: appState.mailCredentials
        )

        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
        let inboxRequests = provider.searchRequests.filter {
            $0.mailbox == .inbox && $0.criteria.subject == "lunch?"
        }
        XCTAssertEqual(inboxRequests.map { $0.offset }, [0, 50])
        XCTAssertEqual(inboxRequests.map { $0.criteria.subject }, ["lunch?", "lunch?"])
        XCTAssertNil(inboxRequests.first?.criteria.maximumUID)
        XCTAssertEqual(inboxRequests.last?.criteria.maximumUID, 200)
    }

    func testVerdictPaginatesSubjectSentUntilReplyFound() async {
        let firstSentPage = (0..<50).map {
            message(
                id: UInt32(300 - $0),
                subject: "Lunch?",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "nobody\($0)@x.com")],
                date: "Tue, 14 Nov 2023 23:00:00 +0000"
            )
        }
        let provider = SearchStubMailProvider()
        provider.pageResults[.inbox] = [
            0: MailSearchResult(
                messages: [message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>")],
                totalMatches: 1,
                offset: 0,
                hasMore: false
            )
        ]
        provider.pageResults[.sent] = [
            0: MailSearchResult(messages: firstSentPage, totalMatches: 51, offset: 0, hasMore: true),
            50: MailSearchResult(messages: [message(
                id: 2,
                subject: "Re: Lunch?",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "alice@x.com")],
                date: "Tue, 14 Nov 2023 23:00:00 +0000"
            )], totalMatches: 51, offset: 50, hasMore: false)
        ]
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(
            for: draft(),
            credentials: appState.mailCredentials
        )

        XCTAssertEqual(verdict, .stale(.alreadyReplied))
        let sentRequests = provider.searchRequests.filter {
            $0.mailbox == .sent && $0.criteria.subject == "lunch?"
        }
        XCTAssertEqual(sentRequests.map { $0.offset }, [0, 50])
        XCTAssertEqual(sentRequests.map { $0.criteria.subject }, ["lunch?", "lunch?"])
        XCTAssertNil(sentRequests.first?.criteria.maximumUID)
        XCTAssertEqual(sentRequests.last?.criteria.maximumUID, 300)
    }

    func testVerdictFindsChangedSubjectReplyByHeaderSearch() async {
        let source = message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>")
        let changedSubjectReply = message(
            id: 9,
            subject: "Updated plan",
            from: MailAddress(email: "carol@x.com"),
            inReplyTo: "<orig@x.com>",
            messageID: "<new@x.com>"
        )
        let provider = SearchStubMailProvider()
        provider.searchHandler = { [weak self] mailbox, criteria, _, _ in
            guard let self else { return nil }
            if mailbox == .inbox && criteria.subject == "lunch?" { return self.result([source]) }
            if mailbox == .inbox && self.hasHeader(criteria, field: "Message-ID", value: "orig@x.com") {
                return self.result([source])
            }
            if mailbox == .inbox && self.hasHeader(criteria, field: "In-Reply-To", value: "orig@x.com") {
                return self.result([changedSubjectReply])
            }
            return .empty(offset: 0)
        }
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(
            for: draft(),
            credentials: appState.mailCredentials
        )

        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
        XCTAssertTrue(provider.searchRequests.contains {
            $0.mailbox == .inbox && hasHeader($0.criteria, field: "In-Reply-To", value: "orig@x.com")
        })
    }

    func testVerdictFindsChangedSubjectSentReplyByHeaderSearch() async {
        let source = message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>")
        let sentReply = message(
            id: 2,
            subject: "Updated plan",
            from: MailAddress(email: "me@gmail.com"),
            to: [MailAddress(email: "alice@x.com")],
            date: "Tue, 14 Nov 2023 23:00:00 +0000",
            inReplyTo: "<orig@x.com>",
            messageID: "<sent@x.com>"
        )
        let provider = SearchStubMailProvider()
        provider.searchHandler = { [weak self] mailbox, criteria, _, _ in
            guard let self else { return nil }
            if mailbox == .inbox && criteria.subject == "lunch?" { return self.result([source]) }
            if mailbox == .sent && criteria.subject == "lunch?" { return .empty(offset: 0) }
            if mailbox == .sent && self.hasHeader(criteria, field: "In-Reply-To", value: "orig@x.com") {
                return self.result([sentReply])
            }
            return .empty(offset: 0)
        }
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(
            for: draft(),
            credentials: appState.mailCredentials
        )

        XCTAssertEqual(verdict, .stale(.alreadyReplied))
        XCTAssertTrue(provider.searchRequests.contains {
            $0.mailbox == .sent && hasHeader($0.criteria, field: "In-Reply-To", value: "orig@x.com")
        })
    }

    func testRegeneratePendingDraftFallsBackToAllMailForMovedSource() async {
        let staleDraft = draft()
        let movedSource = message(id: 50, subject: "Lunch?", uidValidity: 99, messageID: "<orig@x.com>")
        let newerReply = message(
            id: 55,
            subject: "Updated plan",
            uidValidity: 99,
            inReplyTo: "<orig@x.com>",
            messageID: "<new@x.com>"
        )
        let provider = SearchStubMailProvider()
        provider.searchHandler = { [weak self] mailbox, criteria, _, _ in
            guard let self else { return nil }
            if mailbox == .inbox && criteria.subject == "lunch?" { return .empty(offset: 0) }
            if mailbox == .allMail && self.hasHeader(criteria, field: "Message-ID", value: "orig@x.com") {
                return self.result([movedSource])
            }
            if mailbox == .allMail && self.hasHeader(criteria, field: "In-Reply-To", value: "orig@x.com") {
                return self.result([newerReply])
            }
            return .empty(offset: 0)
        }
        let appState = makeAppState(provider: provider, llmText: "Regenerated moved-source reply.")
        appState.pendingDrafts = [staleDraft]

        await appState.regeneratePendingDraft(staleDraft)

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.pendingDrafts.first?.id, 55)
        XCTAssertEqual(appState.pendingDrafts.first?.sourceMailbox, Mailbox.allMail.imapName)
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Regenerated moved-source reply.")
        XCTAssertEqual(provider.lastBodyUID, 55)
        XCTAssertEqual(provider.lastBodyMailbox, .allMail)
    }

    func testRegeneratePendingDraftDoesNotReinsertApprovedReplacement() async throws {
        let staleDraft = draft()
        var approvedReplacement = draft(id: 9)
        approvedReplacement.sourceMessageID = "<new@x.com>"
        let provider = SearchStubMailProvider(
            threadResult: result([
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
            ])
        )
        let appState = makeAppState(provider: provider, llmText: "Regenerated reply.")
        appState.pendingDrafts = [staleDraft]
        let persistence = try XCTUnwrap(appState.persistence as? AppStateMemoryPersistence)
        try persistence.saveApprovedDraftIdentitiesSync([approvedReplacement.identity])

        await appState.approveDraft(staleDraft)
        await appState.regeneratePendingDraft(staleDraft)

        XCTAssertEqual(appState.pendingDrafts, [staleDraft])
        XCTAssertEqual(appState.pendingStaleWarnings[staleDraft.identity], .newerReplyInThread)
        XCTAssertEqual(appState.approvalError, replacementApprovedMessage)
    }

    func testRegeneratePendingDraftDoesNotReinsertReplacementApprovedWhileInFlight() async throws {
        let staleDraft = draft()
        var existingReplacement = draft(id: 9)
        existingReplacement.sourceMessageID = "<new@x.com>"
        existingReplacement.body = "Watcher reply."
        let provider = SearchStubMailProvider(
            threadResult: result([
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
            ])
        )
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        ))
        let llm = SuspendedLLMProvider()
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        appState.pendingDrafts = [staleDraft, existingReplacement]

        await appState.approveDraft(staleDraft)
        let regeneration = Task { await appState.regeneratePendingDraft(staleDraft) }
        await fulfillment(of: [llm.didStartCompletion], timeout: 1)

        await appState.approveDraft(existingReplacement)
        llm.completeDraft(with: .success(LLMResponse(text: "Late regenerated reply.")))
        await regeneration.value

        XCTAssertEqual(provider.sendCount, 1)
        XCTAssertEqual(appState.pendingDrafts, [staleDraft])
        XCTAssertEqual(appState.pendingStaleWarnings[staleDraft.identity], .newerReplyInThread)
        XCTAssertEqual(appState.approvalError, replacementApprovedMessage)
    }
}
