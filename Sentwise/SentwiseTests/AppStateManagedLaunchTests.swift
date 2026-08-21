import XCTest
@testable import Sentwise

/// Launch-time behavior of the managed-inference provider (item 56a): the
/// fresh-install default and restoring the verified state from stored credentials.
@MainActor
final class AppStateManagedLaunchTests: XCTestCase {
    private func makeAppState(
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence = AppStateMemoryPersistence(),
        llm: LLMProviding = FakeLLMProvider(result: .success(()))
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm
        )
    }

    func testDefaultLLMStateIsManagedForFreshInstall() {
        // Managed inference is the default for new installs (item 56a). Not signed
        // in yet, so it is disconnected; the model is the managed default.
        let appState = makeAppState()

        XCTAssertEqual(appState.llmProviderKind, .managed)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.resolvedLLMModel, "claude-sonnet-4-6")
    }

    func testManagedCredentialsRestoreDefaultVerificationOnLaunch() {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmModel: "stale-custom-model",
            llmVerifiedModel: "",
            managedAccountEmail: "marcus@example.com"
        ))

        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertEqual(appState.llmProviderKind, .managed)
        XCTAssertEqual(appState.llmModel, "")
        XCTAssertEqual(appState.verifiedLLMModel, LLMProviderKind.managed.defaultModel)
        XCTAssertTrue(appState.isLLMConnected)
        let saved = persistence.loadSettings()
        XCTAssertEqual(saved.llmModel, "")
        XCTAssertEqual(saved.llmVerifiedModel, LLMProviderKind.managed.defaultModel)
    }
}
