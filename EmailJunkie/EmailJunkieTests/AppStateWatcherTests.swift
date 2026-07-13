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

    /// Builds an AppState that reports connected (account + LLM), with the given
    /// inbox fetch result. `mailAppPassword` is seeded so `isAccountConnected` is
    /// true out of `init`.
    private func makeAppState(
        fetch: Result<[MailMessage], MailError> = .success([]),
        body: Result<Data, MailError> = .success(Data("Please advise.".utf8)),
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "On it.")),
        processed: ProcessedMessages = ProcessedMessages()
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
            processedMessages: processed
        )
        let provider = FakeAppMailProvider(result: .success(()), fetchResult: fetch, bodyResult: body)
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        return (appState, provider, persistence)
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

    func testPollEnqueuesDraftsOldestFirst() async {
        // Real fetch returns newest-first; drafts should enqueue oldest-first.
        let (appState, _, persistence) = makeAppState(
            fetch: .success([message(id: 2), message(id: 1)])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1, 2])
        XCTAssertEqual(appState.pendingDraftCount, 2)
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 1)))
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 2)))
        XCTAssertNil(appState.watchError)
    }

    func testPollSkipsAlreadyProcessed() async {
        var processed = ProcessedMessages()
        processed.insert(message(id: 1))
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

    func testPollMarksProcessedEvenWhenDraftFails() async {
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
        // Processed so a persistent failure doesn't re-draft every poll.
        XCTAssertTrue(persistence.processedMessages.contains(message(id: 1)))
    }
}
