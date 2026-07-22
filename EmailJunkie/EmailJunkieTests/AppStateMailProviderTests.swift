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

    func testLeavesHostUnchangedForUnknownDomain() {
        let app = makeAppState()
        app.mailHost = "imap.gmail.com"
        app.mailEmail = "me@example.org"
        app.applySuggestedHostIfDefault()
        XCTAssertEqual(app.mailHost, "imap.gmail.com")
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
