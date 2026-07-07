import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateDraftTests: XCTestCase {

    private func inboxMessage(id: UInt32 = 5) -> MailMessage {
        MailMessage(id: id, from: MailAddress(name: "Alice", email: "alice@x.com"), subject: "Lunch?", date: "")
    }

    private func makeConnectedAppState(
        fetchBody: Result<Data, MailError> = .success(Data("Are you free Thursday?".utf8)),
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "Sure, Thursday works!"))
    ) -> (AppState, FakeLLMProvider) {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let provider = FakeAppMailProvider(result: .success(()), bodyResult: fetchBody)
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        return (appState, llm)
    }

    func testGenerateDraftProducesDraftTiedToSource() async {
        let (appState, llm) = makeConnectedAppState()
        XCTAssertTrue(appState.canGenerateDraft)

        await appState.generateDraft(for: inboxMessage())

        XCTAssertEqual(appState.generatedDraft?.id, 5)
        XCTAssertEqual(appState.generatedDraft?.body, "Sure, Thursday works!")
        XCTAssertEqual(appState.generatedDraft?.replySubject, "Re: Lunch?")
        XCTAssertEqual(appState.generatedDraft?.sourceFrom?.email, "alice@x.com")
        XCTAssertNil(appState.draftError)
        XCTAssertFalse(appState.isGeneratingDraft)
        XCTAssertEqual(llm.lastAPIKey, "sk-live")
    }

    func testGenerateDraftIgnoresResultAfterAccountChanges() async {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "old@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let provider = FakeAppMailProvider(result: .success(()), bodyResult: .success(Data("Old body".utf8)))
        let llm = SuspendedLLMProvider()
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "old-pw"

        let draftTask = Task { await appState.generateDraft(for: inboxMessage()) }
        await fulfillment(of: [llm.didStartCompletion], timeout: 1)

        appState.mailEmail = "new@gmail.com"
        appState.mailAppPassword = "new-pw"
        await appState.testConnection()

        llm.completeDraft(with: .success(LLMResponse(text: "Stale reply")))
        await draftTask.value

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertNil(appState.generatedDraft)
        XCTAssertNil(appState.draftError)
        XCTAssertFalse(appState.isGeneratingDraft)
    }

    func testGenerateDraftIgnoresErrorAfterDisconnect() async {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "old-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "old@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let provider = FakeAppMailProvider(result: .success(()), bodyResult: .success(Data("Old body".utf8)))
        let llm = SuspendedLLMProvider()
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)

        let draftTask = Task { await appState.generateDraft(for: inboxMessage()) }
        await fulfillment(of: [llm.didStartCompletion], timeout: 1)

        appState.disconnectMail()

        llm.completeDraft(with: .failure(LLMError.http(status: 429, message: "slow down")))
        await draftTask.value

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil(appState.generatedDraft)
        XCTAssertNil(appState.draftError)
        XCTAssertFalse(appState.isGeneratingDraft)
    }

    func testGenerateDraftClearsStaleBodyError() async {
        let (appState, _) = makeConnectedAppState(
            completion: .failure(.http(status: 429, message: "slow down"))
        )
        appState.bodyError = "Previous body preview failed."

        await appState.generateDraft(for: inboxMessage())

        XCTAssertNil(appState.bodyError)
        XCTAssertNil(appState.generatedDraft)
        XCTAssertEqual(appState.draftError, "The provider rejected the request (HTTP 429). slow down")
    }

    func testGenerateDraftInjectsVoiceProfile() async {
        let profile = VoiceProfile(
            greeting: "Hey,", signOff: "M", formality: "casual", tone: "warm",
            averageLength: "short", commonPhrases: ["Sounds good"], summary: "Warm.",
            sampleCount: 4, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            voiceProfile: profile
        )
        let provider = FakeAppMailProvider(result: .success(()), bodyResult: .success(Data("Hi".utf8)))
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "Reply")))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"

        await appState.generateDraft(for: inboxMessage())

        XCTAssertTrue(llm.lastRequest?.system?.contains("Greeting: Hey,") ?? false)
    }

    func testGenerateDraftRequiresConnectedLLM() async {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(),
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.mailAppPassword = "app-pw"

        await appState.generateDraft(for: inboxMessage())

        XCTAssertFalse(appState.canGenerateDraft)
        XCTAssertNil(appState.generatedDraft)
        XCTAssertNotNil(appState.draftError)
    }

    func testGenerateDraftSurfacesLLMError() async {
        let (appState, _) = makeConnectedAppState(
            completion: .failure(.http(status: 429, message: "slow down"))
        )

        await appState.generateDraft(for: inboxMessage())

        XCTAssertNil(appState.generatedDraft)
        XCTAssertEqual(appState.draftError, "The provider rejected the request (HTTP 429). slow down")
    }

    func testGenerateDraftSurfacesEmptyReply() async {
        let (appState, _) = makeConnectedAppState(completion: .success(LLMResponse(text: "  \n")))

        await appState.generateDraft(for: inboxMessage())

        XCTAssertNil(appState.generatedDraft)
        XCTAssertNotNil(appState.draftError)
    }

    func testReplySubjectDoesNotDoublePrefix() {
        XCTAssertEqual(AppState.replySubject(for: "Re: Lunch?"), "Re: Lunch?")
        XCTAssertEqual(AppState.replySubject(for: "Lunch?"), "Re: Lunch?")
    }
}
