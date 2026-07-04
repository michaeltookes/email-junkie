import EmailJunkieMail
import Security
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateTests: XCTestCase {

    private func makeAppState(
        provider: MailProvider,
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence = AppStateMemoryPersistence()
    ) -> AppState {
        AppState(
            persistence: persistence,
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

    func testTestConnectionDoesNotConnectWhenPasswordSaveFails() async {
        let secrets = AppStateFailingSecretStore(seed: [.mailAppPassword: "old-pw"])
        secrets.failOnSet = .mailAppPassword
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "new-pw"

        await appState.testConnection()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertFalse(appState.isConnecting)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "old-pw")
        XCTAssertEqual(provider.lastCredentials?.appPassword, "new-pw")
        XCTAssertEqual(
            appState.connectionError,
            "Couldn't save the app password in Keychain. Keychain returned status -25308."
        )
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
        XCTAssertEqual(appState.mailAppPassword, "")
    }

    func testDisconnectKeepsConnectedStateWhenPasswordRemoveFails() {
        let secrets = AppStateFailingSecretStore(seed: [.mailAppPassword: "app-pw"])
        secrets.failOnRemove = .mailAppPassword
        let provider = FakeAppMailProvider(result: .success(()))
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        let appState = makeAppState(provider: provider, secrets: secrets, persistence: persistence)

        appState.disconnectMail()

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.mailAppPassword, "app-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "app-pw")
        XCTAssertEqual(
            appState.connectionError,
            "Couldn't remove the app password in Keychain. Keychain returned status -25308."
        )
    }
}

private final class AppStateMemoryPersistence: PersistenceProvider {
    private var settings: Settings

    init(settings: Settings = .default) {
        self.settings = settings
    }

    func loadSettings() -> Settings { settings }
    func saveSettings(_ settings: Settings) { self.settings = settings }
    func saveSettingsSync(_ settings: Settings) { self.settings = settings }
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

private final class AppStateFailingSecretStore: SecretStore {
    var failOnSet: SecretKey?
    var failOnRemove: SecretKey?
    private var storage: [String: String]

    init(seed: [SecretKey: String] = [:]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        if failOnSet == key {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        if failOnRemove == key {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}
