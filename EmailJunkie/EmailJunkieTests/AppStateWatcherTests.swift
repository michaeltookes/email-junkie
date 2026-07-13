import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateWatcherTests: XCTestCase {

    private func message(id: UInt32, from: String = "alice@x.com", messageID: String? = nil) -> MailMessage {
        MailMessage(
            id: id,
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

    private func pendingDraft(id: UInt32, messageID: String? = nil, uidValidity: UInt32? = nil) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: uidValidity,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Subject \(id)",
            sourceFrom: MailAddress(name: "Alice", email: "alice@x.com"),
            sourceReplyTo: nil,
            sourceMessageID: messageID ?? "<\(id)@x.com>",
            replySubject: "Re: Subject \(id)",
            body: "On it.",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Builds an AppState that reports connected (account + LLM), with the given
    /// inbox fetch result. `mailAppPassword` is seeded so `isAccountConnected` is
    /// true out of `init`.
    private func makeAppState(
        fetch: Result<[MailMessage], MailError> = .success([]),
        body: Result<Data, MailError> = .success(Data("Please advise.".utf8)),
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "On it.")),
        processed: ProcessedMessages? = nil,
        pendingDrafts: [Draft] = []
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
            processedMessages: processed ?? baselineProcessed(),
            pendingDrafts: pendingDrafts
        )
        let provider = FakeAppMailProvider(result: .success(()), fetchResult: fetch, bodyResult: body)
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        return (appState, provider, persistence)
    }

    private func makeConnectedAppState(mailProvider: MailProvider, llm: LLMProviding) -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        return AppState(persistence: persistence, secrets: secrets, mailProvider: mailProvider, llm: llm)
    }

    // MARK: - Lifecycle

    func testStartWatchingRequiresConnection() {
        let secrets = InMemorySecretStore()  // nothing connected
        let persistence = AppStateMemoryPersistence()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        XCTAssertFalse(appState.canWatch)
        appState.startWatching()

        XCTAssertEqual(appState.watchStatus, .idle)
        XCTAssertNotNil(appState.watchError)
    }

    func testPauseAndStopTransitions() {
        let (appState, _, _) = makeAppState()
        XCTAssertTrue(appState.canWatch)

        appState.watchStatus = .watching
        appState.pauseWatching()
        XCTAssertEqual(appState.watchStatus, .paused)

        appState.toggleWatching()
        XCTAssertEqual(appState.watchStatus, .watching)

        appState.stopWatching()
        XCTAssertEqual(appState.watchStatus, .idle)
    }

    func testDisconnectStopsWatching() {
        let (appState, _, _) = makeAppState()
        appState.watchStatus = .watching

        appState.disconnectMail()

        XCTAssertEqual(appState.watchStatus, .idle)
    }

    // MARK: - Poll policy

    func testPollDoesNothingWhenNotWatching() async {
        let (appState, _, _) = makeAppState(fetch: .success([message(id: 1)]))
        // watchStatus defaults to .idle
        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testFirstPollSeedsBaselineWithoutDraftingHistoricalMessages() async {
        let (appState, provider, persistence) = makeAppState(
            fetch: .success([message(id: 2), message(id: 1)]),
            processed: ProcessedMessages()
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
        XCTAssertTrue(persistence.processedMessages.hasBaseline(account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 2), account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(persistence.processedSaveCount, 1)
    }

    func testEmptyFirstPollStillSeedsBaseline() async {
        let (appState, _, persistence) = makeAppState(
            fetch: .success([]),
            processed: ProcessedMessages()
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(persistence.processedMessages.hasBaseline(account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(persistence.processedSaveCount, 1)
    }

    func testPollEnqueuesDraftsOldestFirst() async {
        // Real fetch returns newest-first; drafts should enqueue oldest-first.
        let (appState, _, persistence) = makeAppState(
            fetch: .success([message(id: 2), message(id: 1)])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1, 2])
        XCTAssertEqual(appState.pendingDraftCount, 2)
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 2), account: "me@gmail.com", mailbox: .inbox))
        XCTAssertNil(appState.watchError)
    }

    func testPollSkipsAlreadyProcessed() async {
        var processed = baselineProcessed()
        processed.insert(message(id: 1), account: "me@gmail.com", mailbox: .inbox)
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 2), message(id: 1)]),
            processed: processed
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [2])
    }

    func testPollNeverDraftsSameMessageTwiceAcrossPolls() async {
        let (appState, _, _) = makeAppState(fetch: .success([message(id: 1)]))
        appState.watchStatus = .watching

        await appState.pollInboxOnce()
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
    }

    func testPollSkipsMessageThatAlreadyHasPendingDraft() async {
        let (appState, provider, persistence) = makeAppState(
            fetch: .success([message(id: 1)]),
            pendingDrafts: [pendingDraft(id: 1)]
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
        XCTAssertFalse(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
    }

    func testPollSkipsMessagesFromSelf() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "ME@Gmail.com")])  // case-insensitive self
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testPollFetchErrorSurfacesAndEnqueuesNothing() async {
        let (appState, _, _) = makeAppState(fetch: .failure(.connectionFailed("no route")))
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.watchError)
    }

    func testPollDoesNotMarkProcessedWhenDraftFails() async {
        // A message with no sender email is skipped by the replyable gate, so
        // use a real sender but fail the LLM to exercise the draft-failure path.
        let (appState, _, persistence) = makeAppState(
            fetch: .success([message(id: 1)]),
            completion: .failure(.http(status: 500, message: "boom"))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.watchError)
        XCTAssertFalse(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
    }

    func testPollPersistsPendingDraftBeforeMarkingProcessed() async {
        let (appState, _, persistence) = makeAppState(fetch: .success([message(id: 1)]))
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(persistence.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(persistence.saveEvents, ["pending", "processed"])
    }

    func testPollDoesNotMarkProcessedWhenPendingDraftSaveFails() async {
        let (appState, _, persistence) = makeAppState(fetch: .success([message(id: 1)]))
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.watchError)
        XCTAssertFalse(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.saveEvents.isEmpty)
    }

    func testDraftAndEnqueueDoesNotCallLLMAfterWatcherStopsDuringBodyFetch() async {
        let provider = SuspendedBodyMailProvider()
        let llm = SuspendedLLMProvider()
        let appState = makeConnectedAppState(mailProvider: provider, llm: llm)
        appState.watchStatus = .watching

        let draftTask = Task { try? await appState.draftAndEnqueue(message(id: 1)) }
        await fulfillment(of: [provider.didStartBodyFetch], timeout: 1)

        appState.pauseWatching()
        provider.completeBody(with: .success(Data("Stale body".utf8)))
        await draftTask.value

        XCTAssertEqual(appState.watchStatus, .paused)
        XCTAssertNil(llm.lastRequest)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.pendingDraftCount, 0)
    }

    func testDraftAndEnqueueDropsResultAfterAccountChangesDuringLLM() async {
        let provider = FakeAppMailProvider(
            result: .success(()),
            bodyResult: .success(Data("Please advise.".utf8))
        )
        let llm = SuspendedLLMProvider()
        let appState = makeConnectedAppState(mailProvider: provider, llm: llm)
        appState.watchStatus = .watching

        let draftTask = Task { try? await appState.draftAndEnqueue(message(id: 1)) }
        await fulfillment(of: [llm.didStartCompletion], timeout: 1)

        appState.mailEmail = "new@gmail.com"
        appState.mailAppPassword = "new-pw"
        llm.completeDraft(with: .success(LLMResponse(text: "Stale reply")))
        await draftTask.value

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.pendingDraftCount, 0)
    }
}
