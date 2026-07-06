import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateLLMTests: XCTestCase {

    private func makeAppState(
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence = AppStateMemoryPersistence(),
        llm: LLMConnectionTesting = FakeLLMConnectionTester(result: .success(()))
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm
        )
    }

    func testDefaultLLMStateIsAnthropicDisconnected() {
        let appState = makeAppState()

        XCTAssertEqual(appState.llmProviderKind, .anthropic)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.resolvedLLMModel, "claude-sonnet-4-6")
    }

    func testResolvedModelUsesCustomModelWhenSet() {
        let appState = makeAppState()
        appState.llmModel = "  claude-haiku-4-5-20251001  "

        XCTAssertEqual(appState.resolvedLLMModel, "claude-haiku-4-5-20251001")
    }

    func testTestLLMConnectionSuccessStoresKeyAndConnects() async {
        let secrets = InMemorySecretStore()
        let tester = FakeLLMConnectionTester(result: .success(()))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.llmAPIKey = "  sk-live  "

        await appState.testLLMConnection()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertNil(appState.llmError)
        XCTAssertFalse(appState.isTestingLLM)
        XCTAssertEqual(tester.lastAPIKey, "sk-live", "key must be trimmed before use")
        XCTAssertEqual(tester.lastModel, "claude-sonnet-4-6")
        XCTAssertEqual(try? secrets.value(for: .llmAPIKey(provider: "anthropic")), "sk-live")
    }

    func testTestLLMConnectionFailureDoesNotStoreKey() async {
        let secrets = InMemorySecretStore()
        let tester = FakeLLMConnectionTester(result: .failure(.http(status: 401, message: "bad key")))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.llmAPIKey = "sk-wrong"

        await appState.testLLMConnection()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertNotNil(appState.llmError)
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "anthropic"))) ?? nil)
    }

    func testTestLLMConnectionRequiresKey() async {
        let tester = FakeLLMConnectionTester(result: .success(()))
        let appState = makeAppState(llm: tester)
        appState.llmAPIKey = "   "

        await appState.testLLMConnection()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertNotNil(appState.llmError)
        XCTAssertNil(tester.lastAPIKey, "tester must not be called without a key")
    }

    func testDisconnectLLMClearsStoredKey() async {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        appState.llmAPIKey = "sk-live"
        await appState.testLLMConnection()

        appState.disconnectLLM()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.llmAPIKey, "")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "anthropic"))) ?? nil)
    }

    func testLLMKeyAndModelRestoredOnInit() {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-stored"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "anthropic",
            llmModel: "claude-opus-4-8"
        ))
        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(appState.llmAPIKey, "sk-stored")
        XCTAssertEqual(appState.llmModel, "claude-opus-4-8")
        XCTAssertEqual(appState.resolvedLLMModel, "claude-opus-4-8")
    }
}
