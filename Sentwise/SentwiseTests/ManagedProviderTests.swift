import XCTest
@testable import Sentwise

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

    // MARK: - Error messages

    func testManagedMessageNamesMissingSignUpFields() {
        let message = AppState.managedMessage(for: ClerkError.notComplete(status: "missing_requirements", missingFields: ["password"]))
        XCTAssertTrue(message.contains("password"), message)
        XCTAssertTrue(message.contains("configuration issue"), message)
        // Without missing fields it stays the generic bad-code message.
        XCTAssertTrue(AppState.managedMessage(for: ClerkError.notComplete(status: "needs_second_factor")).contains("Request a new code"))
    }

    func testManagedMessageMapsTransportErrorsToCouldNotReach() {
        let expected = "Couldn't reach Sentwise sign-in. Check your connection and try again."
        // A transport failure while minting a token surfaces as LLMError.transport.
        XCTAssertEqual(AppState.managedMessage(for: LLMError.transport("offline")), expected)
        // Clerk-layer transport failures map to the same message.
        XCTAssertEqual(AppState.managedMessage(for: ClerkError.transport("dns")), expected)
        // Not-signed-in stays its own message.
        XCTAssertEqual(AppState.managedMessage(for: LLMError.managedNotSignedIn), "Sign-in didn't stick. Please try again.")
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

    func testMigrationClearsStaleCustomModelWhenMovingToManaged() {
        let settings = Settings(
            schemaVersion: 14,
            pollIntervalSeconds: 300,
            llmProvider: "anthropic",
            llmModel: "claude-opus-custom"
        )
        let migrated = migrate(settings, secrets: InMemorySecretStore())

        XCTAssertEqual(migrated.llmProvider, "managed")
        XCTAssertEqual(migrated.llmModel, "")
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
