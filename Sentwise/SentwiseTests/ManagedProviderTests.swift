import SentwiseMail
import XCTest
@testable import Sentwise

/// A `ManagedSessionProviding` double for LLMService routing tests.
private struct FixedSessionProvider: ManagedSessionProviding {
    let token: String
    func currentSessionToken() async throws -> String { token }
}

private enum ManagedProviderSecretError: Error {
    case removeDenied
}

private final class ManagedProviderFailingRemoveSecretStore: SecretStore {
    var failOnRemoveKeys: Set<SecretKey> = []
    private var storage: [String: String]

    init(seed: [SecretKey: String]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        if failOnRemoveKeys.contains(key) {
            throw ManagedProviderSecretError.removeDenied
        }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}

private final class ManagedProviderQueueClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private var responses: [ClerkHTTPResponse]

    init(_ responses: [ClerkHTTPResponse]) {
        self.responses = responses
    }

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        guard !responses.isEmpty else { return ClerkHTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        return responses.removeFirst()
    }
}

private final class ManagedProviderSuspendedLLMTransport: LLMHTTPTransport, @unchecked Sendable {
    let didStartRequest = XCTestExpectation(description: "managed LLM request started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, Error>?

    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            didStartRequest.fulfill()
        }
    }

    func complete(with result: Result<HTTPResponse, Error>) {
        lock.lock()
        let storedContinuation = continuation
        self.continuation = nil
        lock.unlock()
        storedContinuation?.resume(with: result)
    }
}

private func managedProviderClerkResponse(
    _ json: String,
    status: Int = 200,
    clientToken: String? = nil
) -> ClerkHTTPResponse {
    var headers: [String: String] = [:]
    if let clientToken { headers["authorization"] = "Bearer \(clientToken)" }
    return ClerkHTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
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

    func testManagedSignInStoresPendingFlowEmailWhenInputChangesBeforeVerify() async throws {
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed"
        ))
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(
                    #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                    clientToken: "client_A"
                ),
                managedProviderClerkResponse(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
                managedProviderClerkResponse(
                    #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#,
                    clientToken: "client_C"
                ),
                managedProviderClerkResponse(#"{"jwt":"session.jwt"}"#, clientToken: "client_D")
            ])
        )
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            managedAccount: managedAccount
        )

        appState.managedEmailInput = "marcus@example.com"
        await appState.startManagedSignIn()

        appState.managedEmailInput = "wrong@example.com"
        appState.managedCodeInput = "123456"
        await appState.verifyManagedCode()

        XCTAssertEqual(appState.managedAccountEmail, "marcus@example.com")
        XCTAssertEqual(appState.managedEmailInput, "marcus@example.com")
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testSignOutManagedKeepsPublishedStateWhenKeychainRemovalFails() async throws {
        let secrets = ManagedProviderFailingRemoveSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        await appState.signOutManaged()

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "marcus@example.com")
        XCTAssertNotNil(appState.managedError)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testSignOutManagedClearsPublishedStateWhenCredentialRemovalIsPartial() async throws {
        let secrets = ManagedProviderFailingRemoveSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedSessionID]
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        await appState.signOutManaged()

        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertNotNil(appState.managedError)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testManagedAuthInvalidationDuringDraftClearsPublishedAccountState() async throws {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: "me@gmail.com"): "app-pw",
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(#"{"errors":[{"message":"expired"}]}"#, status: 401)
            ])
        )
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let llm = LLMService(
            transport: FakeLLMTransport(response: HTTPResponse(
                statusCode: 200,
                body: Data(#"{"text":"ok"}"#.utf8)
            )),
            managedSessionProvider: managedAccount
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                bodyResult: .success(Data("Are you free Thursday?".utf8))
            ),
            llm: llm,
            managedAccount: managedAccount
        )

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        let draft = await appState.generateDraft(for: MailMessage(
            id: 5,
            from: MailAddress(name: "Alice", email: "alice@example.com"),
            subject: "Lunch?",
            date: ""
        ))

        XCTAssertNil(draft)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertEqual(appState.draftError, "Sign in to Sentwise AI first (Settings → AI).")
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testManagedProxyAuthFailureDuringDraftClearsPublishedAccountState() async throws {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: "me@gmail.com"): "app-pw",
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(#"{"jwt":"live.jwt"}"#, clientToken: "client_Y")
            ])
        )
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let llm = LLMService(
            transport: FakeLLMTransport(response: HTTPResponse(
                statusCode: 401,
                body: Data(#"{"error":{"type":"unauthenticated","message":"Sign in."}}"#.utf8)
            )),
            managedSessionProvider: managedAccount
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                bodyResult: .success(Data("Are you free Thursday?".utf8))
            ),
            llm: llm,
            managedAccount: managedAccount
        )

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        let draft = await appState.generateDraft(for: MailMessage(
            id: 5,
            from: MailAddress(name: "Alice", email: "alice@example.com"),
            subject: "Lunch?",
            date: ""
        ))

        XCTAssertNil(draft)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertEqual(appState.draftError, "Sign in to Sentwise AI first (Settings → AI).")
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testManagedProxyAuthFailureFromStaleDraftStillClearsPublishedAccountState() async throws {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: "me@gmail.com"): "app-pw",
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(#"{"jwt":"live.jwt"}"#, clientToken: "client_Y")
            ])
        )
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let transport = ManagedProviderSuspendedLLMTransport()
        let llm = LLMService(
            transport: transport,
            managedSessionProvider: managedAccount
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                bodyResult: .success(Data("Are you free Thursday?".utf8))
            ),
            llm: llm,
            managedAccount: managedAccount
        )

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        let draftTask = Task {
            await appState.generateDraft(for: MailMessage(
                id: 5,
                from: MailAddress(name: "Alice", email: "alice@example.com"),
                subject: "Lunch?",
                date: ""
            ))
        }
        await fulfillment(of: [transport.didStartRequest], timeout: 1.0)

        appState.selectLLMProvider(.anthropic)
        transport.complete(with: .success(HTTPResponse(
            statusCode: 401,
            body: Data(#"{"error":{"type":"unauthenticated","message":"Sign in."}}"#.utf8)
        )))
        let draft = await draftTask.value

        XCTAssertNil(draft)
        XCTAssertEqual(appState.llmProviderKind, .anthropic)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertNil(appState.draftError)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }
}
