import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateTests: XCTestCase {

    func testConnectStopsWhenCredentialSavePartiallyFails() async {
        let secrets = PartiallyFailingSecretStore(seed: [
            .googleClientID: "old-client-id",
            .googleClientSecret: "old-client-secret"
        ])
        let store = GmailAuthStore(secrets: secrets)
        let browser = AppStateSpyBrowser()
        let coordinator = GmailAuthCoordinator(
            store: store,
            tokenService: OAuthTokenService(transport: AppStateFakeTransport()),
            makeListener: {
                AppStateFakeRedirectListener(
                    redirectURI: "http://127.0.0.1:9999",
                    params: ["code": "auth-code", "state": "state"]
                )
            },
            browser: browser,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            makeState: { "state" }
        )
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            gmailStore: store,
            gmailAuth: coordinator
        )
        appState.clientIDInput = "new-client-id"
        appState.clientSecretInput = "new-client-secret"
        secrets.failOnSet = .googleClientSecret

        await appState.connectGmail()

        XCTAssertNil(browser.openedURL)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertFalse(appState.isConnecting)
        XCTAssertEqual(appState.connectionError, "Unable to save Gmail credentials.")
    }
}

private final class AppStateMemoryPersistence: PersistenceProvider {
    func loadSettings() -> Settings { .default }
    func saveSettings(_ settings: Settings) {}
    func saveSettingsSync(_ settings: Settings) {}
}

private enum AppStateSecretError: LocalizedError {
    case saveFailed

    var errorDescription: String? {
        "Unable to save Gmail credentials."
    }
}

private final class PartiallyFailingSecretStore: SecretStore {
    var failOnSet: SecretKey?
    private var storage: [String: String]

    init(seed: [SecretKey: String] = [:]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        if failOnSet == key {
            throw AppStateSecretError.saveFailed
        }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}

private struct AppStateFakeTransport: HTTPTransport {
    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            body: Data(#"{"access_token":"at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer","scope":"s"}"#.utf8)
        )
    }
}

private final class AppStateFakeRedirectListener: RedirectListener {
    private let redirectURI: String
    private let params: [String: String]

    init(redirectURI: String, params: [String: String]) {
        self.redirectURI = redirectURI
        self.params = params
    }

    func start() async throws -> String { redirectURI }
    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] { params }
    func stop() {}
}

private final class AppStateSpyBrowser: BrowserOpening {
    private(set) var openedURL: URL?

    func open(_ url: URL) {
        openedURL = url
    }
}
