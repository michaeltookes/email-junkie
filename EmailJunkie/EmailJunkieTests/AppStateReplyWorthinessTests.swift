import EmailJunkieMail
import XCTest
@testable import EmailJunkie

/// Tests the reply-worthiness gate wired into the watcher pipeline (item 17):
/// skipped mail is logged instead of drafted, the skip log is bounded and
/// de-duped, and the user can override a skip to force a draft.
@MainActor
final class AppStateReplyWorthinessTests: XCTestCase {

    private func message(
        id: UInt32,
        uidValidity: UInt32? = nil,
        from: String = "alice@x.com",
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: MailAddress(name: "Alice", email: from),
            subject: "Subject \(id)",
            date: "",
            messageID: messageID ?? "<\(id)@x.com>"
        )
    }

    private func baselineProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        return processed
    }

    private func makeAppState(
        fetch: Result<[MailMessage], MailError> = .success([]),
        header: Result<MailHeaderFields, MailError> = .success(MailHeaderFields()),
        body: Result<Data, MailError> = .success(Data("Please advise.".utf8)),
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "On it.")),
        processed: ProcessedMessages? = nil
    ) -> (AppState, FakeAppMailProvider, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            processedMessages: processed ?? baselineProcessed()
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: body,
            headerResult: header
        )
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        return (appState, provider, persistence)
    }

    // MARK: - Gate

    func testWorthyMessageIsDraftedNotSkipped() async {
        let (appState, provider, _) = makeAppState(fetch: .success([message(id: 1)]))
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(provider.headerFetchCallCount, 1)
    }

    func testNoReplySenderIsSkippedAndLogged() async {
        let (appState, provider, persistence) = makeAppState(
            fetch: .success([message(id: 1, from: "no-reply@x.com")])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.noReplySender])
        XCTAssertEqual(appState.skippedMessages.first?.message.id, 1)
        // Skipped-but-handled: no draft body fetched, marked processed so it is
        // not re-evaluated next poll.
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
    }

    func testBulkMailIsSkippedViaHeaders() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1)]),
            header: .success(MailHeaderFields(listUnsubscribe: "<mailto:unsub@x.com>"))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.bulkOrListMail])
    }

    func testCalendarInviteIsSkippedViaHeaders() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1)]),
            header: .success(MailHeaderFields(contentType: "text/calendar; method=REQUEST"))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.calendarInvite])
    }

    func testHeaderFetchFailureFallsBackToSenderOnlyAndStillDrafts() async {
        // Header fetch fails, but the sender is a real person → still worthy.
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1)]),
            header: .failure(.connectionFailed("no route"))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertNil(appState.watchError)
    }

    func testHeaderFetchFailureStillCatchesNoReplySender() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "noreply@x.com")]),
            header: .failure(.connectionFailed("no route"))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.noReplySender])
    }

    func testSkippedMessageIsNotReloggedAcrossPolls() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "no-reply@x.com")])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.skippedMessages.count, 1)
    }

    // MARK: - Skip log bounds

    func testSkipLogIsBoundedToLimitNewestFirst() {
        let (appState, _, _) = makeAppState()
        let limit = appState.skippedMessageLogLimit

        for id in 1...(limit + 10) {
            appState.recordSkip(
                message(id: UInt32(id), from: "no-reply@x.com"),
                reason: .noReplySender,
                account: "me@gmail.com",
                mailbox: .inbox
            )
        }

        XCTAssertEqual(appState.skippedMessages.count, limit)
        // Newest first: the last recorded id is at the front.
        XCTAssertEqual(appState.skippedMessages.first?.message.id, UInt32(limit + 10))
    }

    func testRecordSkipDeDupesByIdentity() {
        let (appState, _, _) = makeAppState()
        let msg = message(id: 5, uidValidity: 9, from: "no-reply@x.com")

        appState.recordSkip(msg, reason: .noReplySender, account: "me@gmail.com", mailbox: .inbox)
        appState.recordSkip(msg, reason: .bulkOrListMail, account: "me@gmail.com", mailbox: .inbox)

        XCTAssertEqual(appState.skippedMessages.count, 1)
        // Re-recording refreshes the entry to the newest reason.
        XCTAssertEqual(appState.skippedMessages.first?.reason, .bulkOrListMail)
    }

    // MARK: - Override

    func testForceDraftSkippedMessageDraftsAndClearsEntry() async {
        let (appState, provider, persistence) = makeAppState(
            fetch: .success([message(id: 1, from: "no-reply@x.com")])
        )
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        let entry = try! XCTUnwrap(appState.skippedMessages.first)

        let ok = await appState.forceDraftSkippedMessage(entry)

        XCTAssertTrue(ok)
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
        // The override does not re-run the worthiness gate: no extra header fetch.
        XCTAssertEqual(provider.headerFetchCallCount, 1)
    }

    func testForceDraftWorksRegardlessOfWatchState() async {
        let (appState, _, _) = makeAppState()
        appState.recordSkip(
            message(id: 7, from: "no-reply@x.com"),
            reason: .noReplySender,
            account: "me@gmail.com",
            mailbox: .inbox
        )
        let entry = try! XCTUnwrap(appState.skippedMessages.first)
        // watchStatus is .idle — override must still work.
        XCTAssertEqual(appState.watchStatus, .idle)

        let ok = await appState.forceDraftSkippedMessage(entry)

        XCTAssertTrue(ok)
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [7])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }

    func testForceDraftFailureKeepsEntry() async {
        let (appState, _, _) = makeAppState(completion: .failure(.http(status: 500, message: "boom")))
        appState.recordSkip(
            message(id: 3, from: "no-reply@x.com"),
            reason: .noReplySender,
            account: "me@gmail.com",
            mailbox: .inbox
        )
        let entry = try! XCTUnwrap(appState.skippedMessages.first)

        let ok = await appState.forceDraftSkippedMessage(entry)

        XCTAssertFalse(ok)
        XCTAssertEqual(appState.skippedMessages.count, 1)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.watchError)
    }

    // MARK: - Account isolation

    func testSkipLogClearedOnDisconnect() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "no-reply@x.com")])
        )
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        XCTAssertFalse(appState.skippedMessages.isEmpty)

        appState.disconnectMail()

        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }
}
