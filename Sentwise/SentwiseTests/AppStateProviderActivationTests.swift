import XCTest
@testable import Sentwise

/// A fake `LLMHTTPTransport` returning a fixed response (OpenRouter exchange).
private final class ActivationFakeJSONTransport: LLMHTTPTransport, @unchecked Sendable {
    private let response: HTTPResponse
    init(_ response: HTTPResponse) { self.response = response }
    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        response
    }
}

/// AppState-level tests for the item 59 active-provider badge logic, OpenRouter
/// one-click provisioning, and Google sign-in end to end.
@MainActor
final class AppStateProviderActivationTests: XCTestCase {

    private let startResponse =
        #"{"response":{"id":"sia_1","first_factor_verification":"#
            + #"{"external_verification_redirect_url":"https://accounts.google.com/o/oauth2/auth?x=1"}}}"#

    private func makeAppState(
        provider: String = "managed",
        secrets: InMemorySecretStore = InMemorySecretStore(),
        managedAccount: ManagedAccountService? = nil
    ) -> AppState {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: provider
        ))
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            managedAccount: managedAccount
        )
    }

    // MARK: - Active-provider badge logic

    func testActiveProviderFlagsAreMutuallyExclusive() {
        let appState = makeAppState(provider: "managed")
        XCTAssertTrue(appState.isManagedProviderActive)
        XCTAssertFalse(appState.isBYOProviderActive)

        appState.selectLLMProvider(.anthropic)
        XCTAssertFalse(appState.isManagedProviderActive)
        XCTAssertTrue(appState.isBYOProviderActive)
    }

    // MARK: - OpenRouter one-click

    func testBeginOpenRouterProvisioningStoresVerifierAndBuildsURL() throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)

        let url = try XCTUnwrap(appState.beginOpenRouterProvisioning())
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "callback_url" }?.value, "sentwise://openrouter-callback")
        XCTAssertFalse((items.first { $0.name == "code_challenge" }?.value ?? "").isEmpty)
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")

        let verifier = try secrets.value(for: .openRouterPKCEVerifier)
        XCTAssertFalse((verifier ?? "").isEmpty)
    }

    func testHandleOpenRouterCallbackActivatesOpenAICompatibleProvider() async throws {
        let secrets = InMemorySecretStore(seed: [.openRouterPKCEVerifier: "VER"])
        let appState = makeAppState(provider: "managed", secrets: secrets)
        let transport = ActivationFakeJSONTransport(
            HTTPResponse(statusCode: 200, body: Data(#"{"key":"sk-or-xyz"}"#.utf8))
        )

        await appState.handleOpenRouterCallback(
            code: "CODE",
            provisioner: OpenRouterKeyProvisioner(transport: transport)
        )

        XCTAssertEqual(appState.llmProviderKind, .openAICompatible)
        XCTAssertEqual(appState.llmBaseURL, OpenRouterKeyProvisioner.apiBaseURL)
        XCTAssertEqual(appState.llmModel, AppState.openRouterDefaultModel)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertTrue(appState.isBYOProviderActive)
        XCTAssertEqual(try secrets.value(for: LLMProviderKind.openAICompatible.apiKeySecret), "sk-or-xyz")
        XCTAssertNil((try secrets.value(for: .openRouterPKCEVerifier)) ?? nil, "verifier is consumed")
        XCTAssertNil(appState.llmError)
    }

    func testHandleOpenRouterCallbackWithoutVerifierSetsError() async {
        let appState = makeAppState(provider: "managed")

        await appState.handleOpenRouterCallback(code: "CODE")

        XCTAssertNotNil(appState.llmError)
        XCTAssertEqual(appState.llmProviderKind, .managed, "provider is left unchanged on failure")
    }

    // MARK: - URL routing / hunt-mode guard

    func testIncomingCallbackIgnoredDuringHunt() {
        let appState = makeAppState()
        let url = URL(string: "sentwise://openrouter-callback?code=CODE")!

        XCTAssertNil(appState.routableCallback(for: url, isHuntMode: true),
                     "a hunt must never reach the completion paths, even via a stray deep link")
        XCTAssertEqual(appState.routableCallback(for: url, isHuntMode: false), .openRouter(code: "CODE"))
        XCTAssertNil(appState.routableCallback(for: URL(string: "https://evil?code=x")!, isHuntMode: false))
    }

    // MARK: - Google sign-in end to end

    func testGoogleSignInEndToEndSignsInAndActivatesManaged() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(startResponse, clientToken: "client_A"),
            clerkReply(
                #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1","identifier":"marcus@example.com"}}"#,
                clientToken: "client_B"
            ),
            clerkReply(#"{"jwt":"jwt.value"}"#, clientToken: "client_C")
        ])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(provider: "anthropic", secrets: secrets, managedAccount: managed)

        var opened: URL?
        await appState.startManagedGoogleSignIn { opened = $0 }
        XCTAssertEqual(opened?.absoluteString, "https://accounts.google.com/o/oauth2/auth?x=1")

        await appState.handleManagedOAuthCallback(nonce: "nonce_1")

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isManagedProviderActive)
        XCTAssertEqual(appState.managedAccountEmail, "marcus@example.com")
        XCTAssertNil(appState.managedError)
    }
}
