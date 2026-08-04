import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateAccountReviewFeedbackTests: XCTestCase {

    private func makeAppState(
        settings: Settings,
        secrets: SecretStore,
        provider: MailProvider = FakeAppMailProvider(result: .success(()))
    ) -> (AppState, AppStateMemoryPersistence) {
        let persistence = AppStateMemoryPersistence(settings: settings)
        let app = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        return (app, persistence)
    }

    func testSwitchFailureRestartsWatcherOnOutgoingAccount() async {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail.email): "expired-gmail-pw",
            .mailAppPassword(email: att.email): "att-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed("expired password")))
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets, provider: provider)
        app.watchStatus = .watching

        await app.switchToSavedAccount(gmail)

        XCTAssertEqual(app.mailEmail, att.email)
        XCTAssertEqual(app.mailAppPassword, "att-pw")
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertTrue(persistence.processedMessages.hasBaselineStart(account: att.email, mailbox: .inbox))
        app.stopWatching()
    }

    func testRemoveActivePerAccountKeepsInactiveLegacyPassword() {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "legacy-gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets)

        app.removeSavedAccount(att)

        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [gmail])
        XCTAssertEqual(persistence.loadSettings().savedAccounts, [gmail])
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "")
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: att.email))) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "legacy-gmail-pw")
    }

    func testDisconnectPreservesInactiveLegacyPasswordWhenActiveHasPerAccountSecret() {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "legacy-gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let (app, _) = makeAppState(settings: settings, secrets: secrets)

        app.disconnectMail()

        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailAppPassword, "")
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: att.email))) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "legacy-gmail-pw")
    }
}
