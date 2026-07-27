import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateMailProviderTests: XCTestCase {

    private func makeAppState() -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore()
        )
    }

    // MARK: - suggestedIMAPHost

    func testSuggestsHostForKnownDomains() {
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "me@att.net"), "imap.mail.att.net")
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "me@yahoo.com"), "imap.mail.yahoo.com")
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "me@ymail.com"), "imap.mail.yahoo.com")
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "me@rocketmail.com"), "imap.mail.yahoo.com")
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "Me@GMAIL.com"), "imap.gmail.com")
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "me@sbcglobal.net"), "imap.mail.att.net")
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "me@icloud.com"), "imap.mail.me.com")
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "me@me.com"), "imap.mail.me.com")
        XCTAssertEqual(AppState.suggestedIMAPHost(forEmail: "me@mac.com"), "imap.mail.me.com")
    }

    func testSuggestsNothingForUnknownOrMalformed() {
        XCTAssertNil(AppState.suggestedIMAPHost(forEmail: "me@example.org"))
        XCTAssertNil(AppState.suggestedIMAPHost(forEmail: "not-an-email"))
        XCTAssertNil(AppState.suggestedIMAPHost(forEmail: ""))
    }

    // MARK: - applySuggestedHostIfDefault

    func testAutoFillsHostFromDomainWhenHostIsDefault() {
        let app = makeAppState()
        app.mailHost = "imap.gmail.com" // a recognized provider default
        app.mailEmail = "me@att.net"
        app.applySuggestedHostIfDefault()
        XCTAssertEqual(app.mailHost, "imap.mail.att.net")
    }

    func testDoesNotOverwriteACustomHost() {
        let app = makeAppState()
        app.mailHost = "imap.customdomain.example" // user-entered custom host
        app.mailEmail = "me@att.net"
        app.applySuggestedHostIfDefault()
        XCTAssertEqual(app.mailHost, "imap.customdomain.example", "custom host preserved")
    }

    func testClearsReplaceableHostForUnknownDomain() {
        let app = makeAppState()
        app.mailHost = "imap.mail.att.net"
        app.mailEmail = "me@example.org"
        app.applySuggestedHostIfDefault()
        XCTAssertEqual(app.mailHost, "")
        XCTAssertNil(app.credentialGuidanceHostFallback)
    }

    func testLeavesCustomHostUnchangedForUnknownDomain() {
        let app = makeAppState()
        app.mailHost = "imap.customdomain.example"
        app.mailEmail = "me@example.org"
        app.applySuggestedHostIfDefault()
        XCTAssertEqual(app.mailHost, "imap.customdomain.example", "custom host preserved")
    }

    func testUnknownDomainUsesGenericGuidanceUntilHostIsExplicitlyEntered() {
        let app = makeAppState()
        app.mailHost = "imap.gmail.com"
        app.updateMailEmailFromUser("me@company.example")
        XCTAssertEqual(app.mailHost, "")
        XCTAssertEqual(
            CredentialGuidance.forEmail(
                app.mailEmail,
                explicitHostFallback: app.credentialGuidanceHostFallback
            ),
            CredentialGuidance.generic
        )

        app.updateMailHostFromUser("imap.gmail.com")
        XCTAssertEqual(
            CredentialGuidance.forEmail(
                app.mailEmail,
                explicitHostFallback: app.credentialGuidanceHostFallback
            ).providerName,
            "Gmail"
        )
    }

    func testPreservesExplicitProviderHostForSameUnknownDomainEmailEdits() {
        let app = makeAppState()
        app.updateMailEmailFromUser("me@company.example")

        app.updateMailHostFromUser("imap.gmail.com")
        app.updateMailEmailFromUser("renamed@company.example")

        XCTAssertEqual(app.mailHost, "imap.gmail.com")
        XCTAssertEqual(app.credentialGuidanceHostFallback, "imap.gmail.com")
        XCTAssertEqual(
            CredentialGuidance.forEmail(
                app.mailEmail,
                explicitHostFallback: app.credentialGuidanceHostFallback
            ).providerName,
            "Gmail"
        )
    }

    func testChangingUnknownDomainClearsExplicitProviderHost() {
        let app = makeAppState()
        app.updateMailEmailFromUser("me@company.example")
        app.updateMailHostFromUser("imap.gmail.com")

        app.updateMailEmailFromUser("me@other-company.example")

        XCTAssertEqual(app.mailHost, "")
        XCTAssertNil(app.credentialGuidanceHostFallback)
        XCTAssertEqual(
            CredentialGuidance.forEmail(
                app.mailEmail,
                explicitHostFallback: app.credentialGuidanceHostFallback
            ),
            CredentialGuidance.generic
        )
    }

    func testRecognizedDomainSupersedesExplicitProviderHostFromCustomDomain() {
        let app = makeAppState()
        app.updateMailEmailFromUser("me@company.example")
        app.updateMailHostFromUser("imap.gmail.com")

        app.updateMailEmailFromUser("me@yahoo.com")

        XCTAssertEqual(app.mailHost, "imap.mail.yahoo.com")
        XCTAssertNil(app.credentialGuidanceHostFallback)
        XCTAssertEqual(
            CredentialGuidance.forEmail(
                app.mailEmail,
                explicitHostFallback: app.credentialGuidanceHostFallback
            ).providerName,
            "Yahoo"
        )
    }

    func testDisconnectPreservesVerifiedProviderHostGuidanceForCustomDomain() async {
        let provider = FakeAppMailProvider(result: .success(()))
        let app = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: provider
        )
        app.updateMailEmailFromUser("me@company.example")
        app.updateMailHostFromUser("imap.gmail.com")
        app.mailAppPassword = "verified-pw"

        await app.testConnection()

        XCTAssertNil(app.connectionError)
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(provider.lastCredentials?.host, "imap.gmail.com")
        XCTAssertEqual(app.credentialGuidanceHostFallback, "imap.gmail.com")

        app.disconnectMail()

        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "me@company.example")
        XCTAssertEqual(app.mailHost, "imap.gmail.com")
        XCTAssertEqual(app.credentialGuidanceHostFallback, "imap.gmail.com")
        XCTAssertEqual(
            CredentialGuidance.forEmail(
                app.mailEmail,
                explicitHostFallback: app.credentialGuidanceHostFallback
            ).providerName,
            "Gmail"
        )
    }

    func testLoadedIncompleteCustomDomainKeepsGenericGuidance() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@company.example",
            mailHost: ""
        ).validated()
        let app = AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: InMemorySecretStore()
        )

        XCTAssertEqual(app.mailHost, "")
        XCTAssertNil(app.credentialGuidanceHostFallback)
        XCTAssertEqual(
            CredentialGuidance.forEmail(
                app.mailEmail,
                explicitHostFallback: app.credentialGuidanceHostFallback
            ),
            CredentialGuidance.generic
        )
    }

    func testClearingExplicitHostRemovesGuidanceFallback() {
        let app = makeAppState()
        app.updateMailEmailFromUser("me@company.example")
        app.updateMailHostFromUser("imap.gmail.com")
        XCTAssertEqual(app.credentialGuidanceHostFallback, "imap.gmail.com")

        app.updateMailHostFromUser(" ")

        XCTAssertNil(app.credentialGuidanceHostFallback)
    }

    func testICloudSuggestionUsesICloudMailboxLayout() {
        let app = makeAppState()
        app.mailHost = "imap.gmail.com"
        app.mailEmail = "me@icloud.com"
        app.applySuggestedHostIfDefault()
        XCTAssertEqual(app.mailHost, "imap.mail.me.com")
        XCTAssertEqual(app.connectedMailboxNaming, .icloud)
        XCTAssertFalse(app.supportsAllMailFolder, "iCloud has no all-mail folder")
    }

    // MARK: - supportsAllMailFolder

    func testAllMailSupportTracksProvider() {
        let app = makeAppState()
        app.mailHost = "imap.gmail.com"
        XCTAssertTrue(app.supportsAllMailFolder)
        app.mailHost = "imap.mail.att.net"
        XCTAssertFalse(app.supportsAllMailFolder, "Yahoo/AT&T has no all-mail folder")
        app.mailHost = "imap.mail.me.com"
        XCTAssertFalse(app.supportsAllMailFolder, "iCloud has no all-mail folder")
    }
}
