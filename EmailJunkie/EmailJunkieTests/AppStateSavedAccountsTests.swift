import EmailJunkieMail
import XCTest
@testable import EmailJunkie

/// Tests for saved accounts (item 48): the v10→v11 migration, per-account
/// Keychain secrets, one-tap switching that retains every account's credentials,
/// removal that deletes only one account's secret, and persistence across relaunch.
@MainActor
final class AppStateSavedAccountsTests: XCTestCase {

    private func makeAppState(
        settings: Settings = .default,
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence? = nil,
        provider: MailProvider = FakeAppMailProvider(result: .success(()))
    ) -> (AppState, AppStateMemoryPersistence, SecretStore) {
        let store = persistence ?? AppStateMemoryPersistence(settings: settings)
        let app = AppState(
            persistence: store,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        return (app, store, secrets)
    }

    /// Connects `email` with `password` through the normal verify path.
    private func connect(_ app: AppState, email: String, host: String, password: String) async {
        app.mailEmail = email
        app.mailHost = host
        app.mailPort = 993
        app.mailAppPassword = password
        await app.testConnection()
    }

    // MARK: - Migration (v10 → v11)

    func testMigrationMovesLegacySecretAndSeedsSavedAccount() {
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "legacy-pw"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: 10,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            mailHost: "imap.gmail.com",
            mailPort: 993
        ))
        let (app, store, _) = makeAppState(secrets: secrets, persistence: persistence)

        // The existing account becomes the first saved account.
        XCTAssertEqual(app.savedAccounts, [
            SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        ])
        // The secret moved to the per-account key and the legacy slot is gone.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "legacy-pw")
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
        // The upgraded settings were persisted at the new schema version.
        XCTAssertEqual(store.loadSettings().schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(store.loadSettings().savedAccounts.map(\.email), ["me@gmail.com"])
        // The account is still connected, from the migrated per-account secret.
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailAppPassword, "legacy-pw")
    }

    func testMigrationIsIdempotentAcrossRelaunch() {
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "legacy-pw"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: 10,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            mailHost: "imap.gmail.com",
            mailPort: 993
        ))
        _ = makeAppState(secrets: secrets, persistence: persistence)
        // A second launch over the already-migrated store must not duplicate.
        let (relaunched, _, _) = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertEqual(relaunched.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
        XCTAssertTrue(relaunched.isAccountConnected)
    }

    func testMigrationWithNoAccountJustBumpsSchema() {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: 10,
            pollIntervalSeconds: 300,
            mailEmail: ""
        ))
        let (app, store, _) = makeAppState(persistence: persistence)

        XCTAssertTrue(app.savedAccounts.isEmpty)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(store.loadSettings().schemaVersion, Settings.currentSchemaVersion)
    }

    // MARK: - Add / per-account secret CRUD

    func testConnectingRemembersAccountUnderPerAccountKey() async {
        let secrets = InMemorySecretStore()
        let (app, store, _) = makeAppState(secrets: secrets)

        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "gmail-pw")
        XCTAssertEqual(store.loadSettings().savedAccounts.map(\.email), ["me@gmail.com"])
    }

    func testConnectingSecondAccountKeepsBothSecrets() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)

        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        XCTAssertEqual(app.savedAccounts.map(\.email), ["me@gmail.com", "me@att.net"])
        // Connecting the second account did NOT overwrite the first's secret.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@att.net")), "att-pw")
        XCTAssertTrue(app.isActiveAccount(app.savedAccounts[1]))
        XCTAssertFalse(app.isActiveAccount(app.savedAccounts[0]))
    }

    // MARK: - Switching

    func testSwitchToSavedAccountRetainsBothCredentials() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        await app.switchToSavedAccount(gmail)

        XCTAssertNil(app.connectionError)
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "me@gmail.com")
        XCTAssertEqual(app.mailAppPassword, "gmail-pw")
        XCTAssertTrue(app.isActiveAccount(gmail))
        // Both accounts' secrets survive the switch.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@att.net")), "att-pw")
    }

    func testSwitchPreservesPendingDrafts() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        let draft = Draft(
            id: 42,
            sourceUIDValidity: 7,
            sourceAccountEmail: "me@att.net",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Hi",
            sourceFrom: MailAddress(email: "friend@att.net"),
            sourceReplyTo: nil,
            sourceMessageID: "<msg-42@att.net>",
            replySubject: "Re: Hi",
            body: "Reply",
            model: "test-model",
            generatedAt: Date()
        )
        app.pendingDrafts = [draft]

        await app.switchToSavedAccount(
            SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        )

        // Pending drafts are account-scoped by identity, so switching leaves them.
        XCTAssertEqual(app.pendingDrafts.map(\.id), [42])
    }

    func testSwitchingToActiveAccountIsANoOp() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")

        let active = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        await app.switchToSavedAccount(active)

        XCTAssertNil(app.connectionError)
        XCTAssertTrue(app.isActiveAccount(active))
    }

    func testSwitchWithoutStoredSecretSurfacesError() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")

        // A saved account whose secret was never stored (e.g. removed) cannot
        // silently connect — the user is told to reconnect.
        let orphan = SavedMailAccount(email: "ghost@att.net", host: "imap.mail.att.net", port: 993)
        await app.switchToSavedAccount(orphan)

        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(app.mailEmail, "me@gmail.com", "active account unchanged")
    }

    // MARK: - Removal

    func testRemoveInactiveAccountDeletesOnlyItsSecret() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        app.removeSavedAccount(gmail)

        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts.map(\.email), ["me@att.net"])
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: "me@gmail.com"))) ?? nil)
        // The still-active account's secret is untouched.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@att.net")), "att-pw")
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "me@att.net")
    }

    func testRemoveActiveAccountGoesOffline() async {
        let secrets = InMemorySecretStore()
        let (app, store, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")

        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        app.removeSavedAccount(gmail)

        XCTAssertTrue(app.savedAccounts.isEmpty)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: "me@gmail.com"))) ?? nil)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "")
        XCTAssertTrue(store.loadSettings().savedAccounts.isEmpty)
    }

    // MARK: - Persistence across relaunch

    func testActiveAccountPersistsAcrossRelaunch() async {
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence()
        let (app, _, _) = makeAppState(secrets: secrets, persistence: persistence)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        // Fresh AppState over the same persistence + Keychain.
        let (relaunched, _, _) = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertEqual(relaunched.savedAccounts.map(\.email), ["me@gmail.com", "me@att.net"])
        XCTAssertTrue(relaunched.isAccountConnected)
        XCTAssertEqual(relaunched.mailEmail, "me@att.net")
        XCTAssertEqual(relaunched.mailAppPassword, "att-pw")
    }
}
