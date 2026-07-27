import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateMailProviderCustomHostTests: XCTestCase {

    func testSameRecognizedDomainEditPreservesExplicitCustomHost() {
        let app = makeAppState()
        app.updateMailEmailFromUser("me@yahoo.com")
        app.updateMailHostFromUser("imap.proxy.example")

        app.updateMailEmailFromUser("renamed@yahoo.com")

        XCTAssertEqual(app.mailHost, "imap.proxy.example")
        XCTAssertEqual(app.credentialGuidanceHostFallback, "imap.proxy.example")
        XCTAssertEqual(app.buildSettings().mailHostGuidanceEmail, "renamed@yahoo.com")
    }

    func testCustomHostEnteredBeforeRecognizedEmailIsRetained() {
        let app = makeAppState()

        app.updateMailHostFromUser("imap.proxy.example")
        app.updateMailEmailFromUser("me@yahoo.com")

        XCTAssertEqual(app.mailHost, "imap.proxy.example")
        XCTAssertEqual(app.credentialGuidanceHostFallback, "imap.proxy.example")
        XCTAssertEqual(app.buildSettings().mailHostGuidanceEmail, "me@yahoo.com")
    }

    func testVerifiedCustomHostForRecognizedDomainIsSupersededWhenSwitchingProviders() async {
        let app = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(()))
        )
        app.updateMailEmailFromUser("me@yahoo.com")
        app.updateMailHostFromUser("imap.proxy.example")
        app.mailAppPassword = "verified-pw"

        await app.testConnection()
        app.disconnectMail()
        app.updateMailEmailFromUser("me@gmail.com")

        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.mailHost, "imap.gmail.com")
        XCTAssertNil(app.credentialGuidanceHostFallback)
    }

    private func makeAppState() -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore()
        )
    }
}
