import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateVoiceTests: XCTestCase {

    private let profileJSON = #"""
    {"greeting":"Hi,","signOff":"Best,\nMichael","formality":"casual","tone":"warm",
     "averageLength":"short","commonPhrases":["Sounds good"],"summary":"Brief and warm."}
    """#

    private func sentMessage(id: UInt32 = 1) -> MailMessage {
        MailMessage(id: id, from: MailAddress(email: "me@gmail.com"), subject: "Re: Plan", date: "")
    }

    private func makeConnectedAppState(
        fetchResult: Result<[MailMessage], MailError> = .success([]),
        bodyResult: Result<Data, MailError> = .success(Data()),
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "")),
        persistence: AppStateMemoryPersistence? = nil
    ) -> (AppState, AppStateMemoryPersistence, FakeLLMProvider) {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let store = persistence ?? AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let provider = FakeAppMailProvider(result: .success(()), fetchResult: fetchResult, bodyResult: bodyResult)
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: store, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        return (appState, store, llm)
    }

    func testLearnVoiceProfileStoresAndPublishesProfile() async {
        let (appState, store, llm) = makeConnectedAppState(
            fetchResult: .success([sentMessage()]),
            bodyResult: .success(Data("Hi,\n\nSounds good.\n\nBest,\nMichael".utf8)),
            completion: .success(LLMResponse(text: profileJSON))
        )
        XCTAssertTrue(appState.canLearnVoice)

        await appState.learnVoiceProfile()

        XCTAssertEqual(appState.voiceProfile?.greeting, "Hi,")
        XCTAssertEqual(appState.voiceProfile?.sampleCount, 1)
        XCTAssertEqual(store.voiceProfile?.summary, "Brief and warm.")
        XCTAssertNil(appState.voiceError)
        XCTAssertFalse(appState.isLearningVoice)
        XCTAssertEqual(llm.lastProvider, .anthropic)
        XCTAssertEqual(llm.lastAPIKey, "sk-live")
    }

    func testLearnVoiceProfileWithNoSentMessagesSurfacesError() async {
        let (appState, _, _) = makeConnectedAppState(fetchResult: .success([]))

        await appState.learnVoiceProfile()

        XCTAssertNil(appState.voiceProfile)
        XCTAssertNotNil(appState.voiceError)
        XCTAssertFalse(appState.isLearningVoice)
    }

    func testLearnVoiceProfileSkipsEmptyBodies() async {
        let (appState, _, _) = makeConnectedAppState(
            fetchResult: .success([sentMessage()]),
            bodyResult: .success(Data("   \n\n".utf8)),
            completion: .success(LLMResponse(text: profileJSON))
        )

        await appState.learnVoiceProfile()

        // The only message reduced to empty text, so there's nothing to learn from.
        XCTAssertNil(appState.voiceProfile)
        XCTAssertNotNil(appState.voiceError)
    }

    func testLearnVoiceProfileSurfacesLLMError() async {
        let (appState, _, _) = makeConnectedAppState(
            fetchResult: .success([sentMessage()]),
            bodyResult: .success(Data("Real content.".utf8)),
            completion: .failure(.http(status: 429, message: "rate limited"))
        )

        await appState.learnVoiceProfile()

        XCTAssertNil(appState.voiceProfile)
        XCTAssertEqual(appState.voiceError, "The provider rejected the request (HTTP 429). rate limited")
    }

    func testLearnVoiceProfileRejectsLLMChangeBeforeProfileRequest() async {
        let secrets = InMemorySecretStore(seed: [
            .llmAPIKey(provider: "anthropic"): "sk-anthropic",
            .llmAPIKey(provider: "openAICompatible"): "sk-openai"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let mailProvider = SuspendedVoiceSampleMailProvider(messages: [sentMessage()])
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: profileJSON)))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: mailProvider, llm: llm)
        appState.mailAppPassword = "app-pw"

        let task = Task { await appState.learnVoiceProfile() }
        await fulfillment(of: [mailProvider.didStartBodyFetch], timeout: 1)

        appState.selectLLMProvider(.openAICompatible)
        mailProvider.completeBody(with: .success(Data("Real content.".utf8)))
        await task.value

        XCTAssertNil(llm.lastRequest)
        XCTAssertNil(appState.voiceProfile)
        XCTAssertEqual(appState.voiceError, "Connection settings changed. Learn your voice again.")
    }

    func testLearnVoiceProfileRejectsLLMChangeBeforeSavingProfile() async {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let mailProvider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: .success([sentMessage()]),
            bodyResult: .success(Data("Real content.".utf8))
        )
        let llm = SuspendedLLMProvider()
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: mailProvider, llm: llm)
        appState.mailAppPassword = "app-pw"

        let task = Task { await appState.learnVoiceProfile() }
        await fulfillment(of: [llm.didStartCompletion], timeout: 1)

        appState.llmModel = "claude-opus-4-8"
        llm.completeDraft(with: .success(LLMResponse(text: profileJSON)))
        await task.value

        XCTAssertNil(appState.voiceProfile)
        XCTAssertNil(persistence.voiceProfile)
        XCTAssertEqual(appState.voiceError, "Connection settings changed. Learn your voice again.")
    }

    func testLearnVoiceProfileRequiresConnectedLLM() async {
        // No API key seeded → not connected.
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        let provider = FakeAppMailProvider(result: .success(()), fetchResult: .success([sentMessage()]))
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(),
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.mailAppPassword = "app-pw"

        await appState.learnVoiceProfile()

        XCTAssertFalse(appState.canLearnVoice)
        XCTAssertNil(appState.voiceProfile)
        XCTAssertNotNil(appState.voiceError)
    }

    func testForgetVoiceProfileClearsStoredProfile() async {
        let (appState, store, _) = makeConnectedAppState(
            fetchResult: .success([sentMessage()]),
            bodyResult: .success(Data("Real content.".utf8)),
            completion: .success(LLMResponse(text: profileJSON))
        )
        await appState.learnVoiceProfile()
        XCTAssertNotNil(appState.voiceProfile)

        appState.forgetVoiceProfile()

        XCTAssertNil(appState.voiceProfile)
        XCTAssertNil(store.voiceProfile)
    }

    func testExistingProfileLoadedOnInit() {
        let profile = VoiceProfile(
            greeting: "Hey,", signOff: "M", formality: "casual", tone: "warm",
            averageLength: "short", commonPhrases: [], summary: "Loaded.",
            sampleCount: 3, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let persistence = AppStateMemoryPersistence(settings: .default, voiceProfile: profile)
        let (appState, _, _) = makeConnectedAppState(persistence: persistence)

        XCTAssertEqual(appState.voiceProfile?.summary, "Loaded.")
    }
}

private final class SuspendedVoiceSampleMailProvider: MailProvider, @unchecked Sendable {
    let didStartBodyFetch = XCTestExpectation(description: "voice body fetch started")
    private let messages: [MailMessage]
    private let lock = NSLock()
    private var bodyContinuation: CheckedContinuation<Data, Error>?

    init(messages: [MailMessage]) {
        self.messages = messages
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        messages
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            bodyContinuation = continuation
            lock.unlock()
            didStartBodyFetch.fulfill()
        }
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}

    func completeBody(with result: Result<Data, Error>) {
        lock.lock()
        let continuation = bodyContinuation
        bodyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
