import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateTests: XCTestCase {

    private func makeAppState(
        provider: MailProvider,
        secrets: SecretStore = InMemorySecretStore()
    ) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: provider
        )
    }

    func testTestConnectionSuccessSavesPasswordAndConnects() async {
        let secrets = InMemorySecretStore()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"

        await appState.testConnection()

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertFalse(appState.isConnecting)
        XCTAssertNil(appState.connectionError)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "app-pw")
        XCTAssertEqual(provider.lastCredentials?.email, "me@gmail.com")
    }

    func testTestConnectionFailureSurfacesError() async {
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed("bad creds")))
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "wrong"

        await appState.testConnection()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNotNil(appState.connectionError)
    }

    func testTestConnectionRequiresCredentials() async {
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider)
        appState.mailEmail = ""
        appState.mailAppPassword = ""

        await appState.testConnection()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil(provider.lastCredentials, "provider must not be called with incomplete credentials")
        XCTAssertNotNil(appState.connectionError)
    }

    func testDisconnectClearsStoredPassword() async {
        let secrets = InMemorySecretStore()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"
        await appState.testConnection()

        appState.disconnectMail()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
    }
}

private final class AppStateMemoryPersistence: PersistenceProvider {
    func loadSettings() -> Settings { .default }
    func saveSettings(_ settings: Settings) {}
    func saveSettingsSync(_ settings: Settings) {}
}

private final class FakeAppMailProvider: MailProvider, @unchecked Sendable {
    private let result: Result<Void, MailError>
    private(set) var lastCredentials: MailAccountCredentials?

    init(result: Result<Void, MailError>) {
        self.result = result
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        lastCredentials = credentials
        try result.get()
    }
}
