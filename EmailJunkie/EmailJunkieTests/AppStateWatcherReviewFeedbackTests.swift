import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateWatcherReviewFeedbackTests: XCTestCase {

    private func message(id: UInt32) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 10,
            from: MailAddress(name: "Alice", email: "alice@example.com"),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@example.com>"
        )
    }

    private func processedBaseline() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        processed.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 1, uidValidity: 10)
        return processed
    }

    private func makeAppState(
        fetch: Result<[MailMessage], MailError>,
        completion: Result<LLMResponse, LLMError>
    ) -> (AppState, AppStateMemoryPersistence) {
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
            processedMessages: processedBaseline()
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: .success(Data("Can you help?".utf8))
        )
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.retryRunner = .immediate
        return (appState, persistence)
    }

    func testDraftGenerationAuthFailurePausesWatchingAndRecordsAuthFailed() async {
        let (appState, persistence) = makeAppState(
            fetch: .success([message(id: 2)]),
            completion: .failure(.http(status: 401, message: "bad key"))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.watchStatus, .paused)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.watchError)
        XCTAssertEqual(appState.activityEvents.map(\.kind), [.authFailed])
        XCTAssertEqual(persistence.loadActivityEvents().map(\.kind), [.authFailed])
    }
}
