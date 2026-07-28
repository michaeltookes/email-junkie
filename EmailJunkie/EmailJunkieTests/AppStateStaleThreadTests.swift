import EmailJunkieMail
import XCTest
@testable import EmailJunkie

/// A mail provider whose `searchMessages` returns configurable results per
/// mailbox, so the stale-thread re-check (item 12) can be driven without a real
/// server. Records send/append so tests can assert a stale draft was not
/// dispatched.
final class SearchStubMailProvider: MailProvider, @unchecked Sendable {
    var threadResult: MailSearchResult
    var sentResult: MailSearchResult
    var searchError: MailError?
    var threadSearchError: MailError?
    var sentSearchError: MailError?
    var bodyResult: Result<Data, MailError> = .success(Data("Please approve the budget.".utf8))
    private(set) var sendCount = 0
    private(set) var appendCount = 0
    private(set) var lastBodyUID: UInt32?
    private(set) var lastExpectedUIDValidity: UInt32?
    private(set) var searchRequests: [(mailbox: Mailbox, criteria: MailSearchCriteria)] = []

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
        searchRequests.append((mailbox, criteria))
        if mailbox == .sent {
            if let sentSearchError { throw sentSearchError }
            return sentResult
        }
        if let threadSearchError { throw threadSearchError }
        return threadResult
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
final class AppStateStaleThreadTests: XCTestCase {

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
        date: String = "",
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 1,
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

    private func makeAppState(
        provider: SearchStubMailProvider,
        sendBehavior: SendBehavior = .autoSend,
        llmText: String = "Fresh reply."
    ) -> AppState {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: sendBehavior.rawValue
        ))
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: llmText)))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        return appState
    }

    // MARK: - threadStalenessVerdict (IO)

    func testVerdictFreshWhenOnlySourcePresent() async {
        let provider = SearchStubMailProvider(threadResult: result([message(id: 5, subject: "Lunch?")]))
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(for: draft(), credentials: appState.mailCredentials)

        XCTAssertEqual(verdict, .fresh)
    }

    func testVerdictDetectsNewerReply() async {
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?"), message(id: 9, subject: "Re: Lunch?")])
        )
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(for: draft(), credentials: appState.mailCredentials)

        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
    }

    func testVerdictDetectsAlreadyRepliedFromSent() async {
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?")]),
            sentResult: result([message(
                id: 2,
                subject: "Re: Lunch?",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "alice@x.com")],
                date: "Tue, 14 Nov 2023 23:00:00 +0000"
            )])
        )
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(for: draft(), credentials: appState.mailCredentials)

        XCTAssertEqual(verdict, .stale(.alreadyReplied))
    }

    func testVerdictIgnoresSameDaySentReplyBeforeDraftGeneration() async {
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?")]),
            sentResult: result([message(
                id: 2,
                subject: "Re: Lunch?",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "alice@x.com")],
                date: "Tue, 14 Nov 2023 09:00:00 +0000"
            )])
        )
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(for: draft(), credentials: appState.mailCredentials)

        XCTAssertEqual(verdict, .fresh)
        XCTAssertEqual(provider.searchRequests.last?.criteria.since, AppState.dayFloor(draft().generatedAt))
    }

    func testVerdictFailsOpenWhenSearchErrors() async {
        let provider = SearchStubMailProvider()
        provider.searchError = .resultTooLarge
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(for: draft(), credentials: appState.mailCredentials)

        XCTAssertEqual(verdict, .fresh, "a failed freshness check must never block a valid send")
    }

    func testVerdictPreservesThreadConflictWhenSentSearchErrors() async {
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?"), message(id: 9, subject: "Re: Lunch?")])
        )
        provider.sentSearchError = .resultTooLarge
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(for: draft(), credentials: appState.mailCredentials)

        XCTAssertEqual(verdict, .stale(.newerReplyInThread))
    }

    func testVerdictTreatsOnlySentSearchErrorAsEmptyWhenThreadIsFresh() async {
        let provider = SearchStubMailProvider(threadResult: result([message(id: 5, subject: "Lunch?")]))
        provider.sentSearchError = .resultTooLarge
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(for: draft(), credentials: appState.mailCredentials)

        XCTAssertEqual(verdict, .fresh)
    }

    func testVerdictFreshWhenSourceMailboxUnknown() async {
        let provider = SearchStubMailProvider(threadResult: result([message(id: 99, subject: "Whatever")]))
        let appState = makeAppState(provider: provider)
        var noMailbox = draft()
        noMailbox.sourceMailbox = nil

        let verdict = await appState.threadStalenessVerdict(for: noMailbox, credentials: appState.mailCredentials)

        XCTAssertEqual(verdict, .fresh)
    }

    // MARK: - Preview dispatch (approveDraftPreview)

    func testPreviewApprovalBlocksStaleSend() async {
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?"), message(id: 9, subject: "Re: Lunch?")])
        )
        let appState = makeAppState(provider: provider)
        appState.generatedDraft = draft()

        do {
            _ = try await appState.approveDraftPreview(draft())
            XCTFail("expected a stale-thread block")
        } catch let error as DraftDispatchError {
            XCTAssertEqual(error, .staleThread(.newerReplyInThread))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(provider.sendCount, 0, "a stale draft must not be sent")
    }

    func testPreviewApprovalForceSendsDespiteStale() async throws {
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?"), message(id: 9, subject: "Re: Lunch?")])
        )
        let appState = makeAppState(provider: provider)
        appState.generatedDraft = draft()

        let confirmation = try await appState.approveDraftPreview(draft(), force: true)

        XCTAssertEqual(confirmation, "Sent.")
        XCTAssertEqual(provider.sendCount, 1, "send anyway overrides the stale block")
    }

    func testPreviewApprovalSendsWhenFresh() async throws {
        let provider = SearchStubMailProvider(threadResult: result([message(id: 5, subject: "Lunch?")]))
        let appState = makeAppState(provider: provider)
        appState.generatedDraft = draft()

        let confirmation = try await appState.approveDraftPreview(draft())

        XCTAssertEqual(confirmation, "Sent.")
        XCTAssertEqual(provider.sendCount, 1)
    }

    // MARK: - Queue dispatch (approveDraft)

    func testQueueApprovalRaisesWarningAndDoesNotSendWhenStale() async {
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?")]),
            sentResult: result([message(
                id: 2,
                subject: "Re: Lunch?",
                from: MailAddress(email: "me@gmail.com"),
                to: [MailAddress(email: "alice@x.com")],
                date: "Tue, 14 Nov 2023 23:00:00 +0000"
            )])
        )
        let appState = makeAppState(provider: provider)
        appState.pendingDrafts = [draft()]

        await appState.approveDraft(draft())

        XCTAssertEqual(appState.pendingStaleWarnings[draft().identity], .alreadyReplied)
        XCTAssertEqual(provider.sendCount, 0, "a stale queued draft must not be sent")
        XCTAssertEqual(appState.pendingDrafts.count, 1, "the draft stays for the user to decide")
    }

    func testQueueForceApprovalSendsAndClearsWarning() async {
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?"), message(id: 9, subject: "Re: Lunch?")])
        )
        let appState = makeAppState(provider: provider)
        appState.pendingDrafts = [draft()]

        await appState.approveDraft(draft())
        XCTAssertNotNil(appState.pendingStaleWarnings[draft().identity])

        await appState.approveDraft(draft(), force: true)

        XCTAssertEqual(provider.sendCount, 1)
        XCTAssertNil(appState.pendingStaleWarnings[draft().identity], "the warning clears after send anyway")
        XCTAssertTrue(appState.pendingDrafts.isEmpty, "the sent draft leaves the queue")
    }

    func testNotificationApprovalOpensReviewWindowWhenStaleWarningRaised() async {
        let staleDraft = draft()
        let provider = SearchStubMailProvider(
            threadResult: result([message(id: 5, subject: "Lunch?"), message(id: 9, subject: "Re: Lunch?")])
        )
        let appState = makeAppState(provider: provider)
        appState.pendingDrafts = [staleDraft]
        appState.pendingDraftCount = 1
        var openedReview = false
        appState.openReviewHandler = { openedReview = true }

        await appState.handleNotificationAction(.approve(.autoSend), identity: staleDraft.identity)

        XCTAssertEqual(appState.pendingStaleWarnings[staleDraft.identity], .newerReplyInThread)
        XCTAssertTrue(openedReview)
        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(appState.pendingDrafts, [staleDraft])
    }

    func testRegeneratePendingDraftReplacesStaleDraft() async {
        let provider = SearchStubMailProvider(
            threadResult: result([
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
            ])
        )
        let appState = makeAppState(provider: provider, llmText: "Regenerated reply.")
        appState.pendingDrafts = [draft()]

        await appState.approveDraft(draft())
        XCTAssertNotNil(appState.pendingStaleWarnings[draft().identity])

        await appState.regeneratePendingDraft(draft())

        XCTAssertNil(appState.pendingStaleWarnings[draft().identity], "the warning clears on regenerate")
        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.pendingDrafts.first?.id, 9)
        XCTAssertEqual(appState.pendingDrafts.first?.sourceMessageID, "<new@x.com>")
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Regenerated reply.")
        XCTAssertEqual(provider.lastBodyUID, 9)
        XCTAssertEqual(provider.lastExpectedUIDValidity, 1)
        XCTAssertEqual(provider.sendCount, 0, "regenerate does not send")
    }

    func testRegeneratePendingDraftKeepsOriginalWhenGenerationFails() async {
        let staleDraft = draft()
        let provider = SearchStubMailProvider(
            threadResult: result([
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
            ])
        )
        let appState = makeAppState(provider: provider, llmText: "Regenerated reply.")
        appState.pendingDrafts = [staleDraft]

        await appState.approveDraft(staleDraft)
        provider.bodyResult = .failure(.commandFailed("body unavailable"))

        await appState.regeneratePendingDraft(staleDraft)

        XCTAssertEqual(appState.pendingDrafts, [staleDraft])
        XCTAssertEqual(appState.pendingStaleWarnings[staleDraft.identity], .newerReplyInThread)
        XCTAssertNotNil(appState.approvalError)
    }

    func testRegeneratePendingDraftKeepsOriginalWhenReplacementSaveFails() async {
        let staleDraft = draft()
        let provider = SearchStubMailProvider(
            threadResult: result([
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
            ])
        )
        let appState = makeAppState(provider: provider, llmText: "Regenerated reply.")
        appState.pendingDrafts = [staleDraft]

        await appState.approveDraft(staleDraft)
        (appState.persistence as? AppStateMemoryPersistence)?.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        await appState.regeneratePendingDraft(staleDraft)

        XCTAssertEqual(appState.pendingDrafts, [staleDraft])
        XCTAssertEqual(appState.pendingStaleWarnings[staleDraft.identity], .newerReplyInThread)
        XCTAssertNotNil(appState.approvalError)
    }
}
