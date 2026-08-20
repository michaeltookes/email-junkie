import XCTest
@testable import Sentwise

/// A `ManagedSessionProviding` double for LLMService routing tests.
private struct FixedSessionProvider: ManagedSessionProviding {
    let token: String
    func currentSessionToken() async throws -> String { token }
}

@MainActor
final class ManagedProviderTests: XCTestCase {

    // MARK: - Enum

    func testManagedProviderProperties() {
        let managed = LLMProviderKind.managed
        XCTAssertFalse(managed.requiresAPIKey)
        XCTAssertFalse(managed.supportsCustomBaseURL)
        XCTAssertEqual(managed.defaultModel, "claude-sonnet-4-6")
        XCTAssertTrue(managed.displayName.contains("Sentwise"))
        XCTAssertNil(managed.baseURLPlaceholder)
        XCTAssertNil(managed.defaultOpenAICompatibleEndpoint)
    }

    func testManagedIsTheFirstAndDefaultProvider() {
        XCTAssertEqual(LLMProviderKind.allCases.first, .managed)
        XCTAssertEqual(Settings.default.llmProvider, "managed")
        XCTAssertEqual(Settings(schemaVersion: 15, pollIntervalSeconds: 300).llmProvider, "managed")
    }

    // MARK: - Settings migration (14 -> 15)

    private func migrate(_ settings: Settings, secrets: SecretStore) -> Settings {
        AppState.migratedManagedInferenceSettings(
            settings,
            originalSchemaVersion: settings.schemaVersion,
            secrets: secrets,
            persistence: AppStateMemoryPersistence()
        )
    }

    func testMigrationMovesUnconfiguredInstallToManaged() {
        let settings = Settings(schemaVersion: 14, pollIntervalSeconds: 300, llmProvider: "anthropic")
        let migrated = migrate(settings, secrets: InMemorySecretStore())
        XCTAssertEqual(migrated.llmProvider, "managed")
        XCTAssertEqual(migrated.schemaVersion, 15)
    }

    func testMigrationKeepsAConfiguredKeyProvider() {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let settings = Settings(schemaVersion: 14, pollIntervalSeconds: 300, llmProvider: "anthropic")
        let migrated = migrate(settings, secrets: secrets)
        XCTAssertEqual(migrated.llmProvider, "anthropic")
        XCTAssertEqual(migrated.schemaVersion, 15)
    }

    func testMigrationKeepsAProviderWithAVerifiedModel() {
        // e.g. an Ollama user configures without a key but has a verified model.
        let settings = Settings(
            schemaVersion: 14, pollIntervalSeconds: 300,
            llmProvider: "ollama", llmVerifiedModel: "llama3.1"
        )
        let migrated = migrate(settings, secrets: InMemorySecretStore())
        XCTAssertEqual(migrated.llmProvider, "ollama")
    }

    func testMigrationIsIdempotentOnceAtCurrentVersion() {
        let settings = Settings(schemaVersion: 15, pollIntervalSeconds: 300, llmProvider: "anthropic")
        let migrated = migrate(settings, secrets: InMemorySecretStore())
        // Already at the managed-inference version — do not flip a chosen provider.
        XCTAssertEqual(migrated.llmProvider, "anthropic")
    }

    // MARK: - LLMService routing + hunt-mode stub

    func testHuntModeReturnsCannedResponseWithoutNetwork() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(statusCode: 200, body: Data()))
        let service = LLMService(
            transport: transport,
            managedSessionProvider: FixedSessionProvider(token: "unused"),
            isProwlHuntMode: true
        )

        let response = try await service.complete(
            LLMRequest(messages: [LLMMessage(role: .user, content: "Hi")], model: "claude-sonnet-4-6"),
            provider: .managed,
            apiKey: "",
            baseURL: nil
        )

        XCTAssertFalse(response.text.isEmpty)
        XCTAssertNil(transport.lastURL, "hunt-mode managed client must not touch the network")
    }

    func testNonHuntManagedRoutesThroughSessionTokenToProxy() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 200,
            body: Data(#"{"text":"ok","usage":{"inputTokens":1,"outputTokens":1}}"#.utf8)
        ))
        let service = LLMService(
            transport: transport,
            managedSessionProvider: FixedSessionProvider(token: "live-session-jwt"),
            isProwlHuntMode: false
        )

        let response = try await service.complete(
            LLMRequest(messages: [LLMMessage(role: .user, content: "Hi")], model: "claude-sonnet-4-6"),
            provider: .managed,
            apiKey: "",
            baseURL: nil
        )

        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(transport.lastURL, ManagedInference.draftEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer live-session-jwt")
    }
}
