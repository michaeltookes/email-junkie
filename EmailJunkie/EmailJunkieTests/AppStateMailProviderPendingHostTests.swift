import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateMailProviderPendingHostTests: XCTestCase {

    func testHostEnteredBeforeCompletedEmailPersistsAcrossRelaunch() {
        assertPendingHostSurvivesRelaunch { firstLaunch in
            firstLaunch.updateMailHostFromUser("imap.gmail.com")
            firstLaunch.updateMailEmailFromUser("me@company")
        }
    }

    func testHostEnteredAfterPartialEmailPersistsAcrossRelaunch() {
        assertPendingHostSurvivesRelaunch { firstLaunch in
            firstLaunch.updateMailEmailFromUser("me@company")
            firstLaunch.updateMailHostFromUser("imap.gmail.com")
        }
    }

    func testIncompleteEditOfTrackedHostPersistsPendingOwnershipAcrossRelaunch() {
        assertPendingHostSurvivesRelaunch { firstLaunch in
            firstLaunch.updateMailEmailFromUser("me@company.example")
            firstLaunch.updateMailHostFromUser("imap.gmail.com")
            firstLaunch.updateMailEmailFromUser("renamed@company")

            let settings = firstLaunch.buildSettings()
            XCTAssertEqual(settings.mailHostGuidanceEmail, "me@company.example")
            XCTAssertTrue(settings.mailHostGuidancePendingEmail)
        }
    }

    func testIncompleteEditPreservesHostThroughValidLookingTLDPrefix() {
        let app = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore()
        )
        app.updateMailEmailFromUser("me@company.example")
        app.updateMailHostFromUser("imap.gmail.com")

        app.updateMailEmailFromUser("renamed@company")
        app.updateMailEmailFromUser("renamed@company.ex")

        XCTAssertEqual(app.mailHost, "imap.gmail.com")
        XCTAssertNil(app.credentialGuidanceHostFallback)

        app.updateMailEmailFromUser("renamed@company.example")

        XCTAssertEqual(app.mailHost, "imap.gmail.com")
        XCTAssertEqual(app.credentialGuidanceHostFallback, "imap.gmail.com")
        XCTAssertEqual(app.buildSettings().mailHostGuidanceEmail, "renamed@company.example")
        XCTAssertFalse(app.buildSettings().mailHostGuidancePendingEmail)
    }

    func testHostEnteredBeforeEmailPreservesHostThroughValidLookingTLDPrefixUntilCommit() {
        let app = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore()
        )
        app.updateMailHostFromUser("imap.gmail.com")

        app.updateMailEmailFromUser("me@company.ex")
        app.updateMailEmailFromUser("me@company.example")

        XCTAssertEqual(app.mailHost, "imap.gmail.com")
        XCTAssertNil(app.credentialGuidanceHostFallback)
        XCTAssertTrue(app.buildSettings().mailHostGuidancePendingEmail)

        app.commitMailEmailEditFromUser()

        XCTAssertEqual(app.mailHost, "imap.gmail.com")
        XCTAssertEqual(app.credentialGuidanceHostFallback, "imap.gmail.com")
        XCTAssertEqual(app.buildSettings().mailHostGuidanceEmail, "me@company.example")
        XCTAssertFalse(app.buildSettings().mailHostGuidancePendingEmail)
    }

    func testIncompleteEditClearsTrackedHostForDifferentDomainAfterRelaunch() {
        let persistence = AppStateMemoryPersistence()
        let firstLaunch = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore()
        )
        firstLaunch.updateMailEmailFromUser("me@company.example")
        firstLaunch.updateMailHostFromUser("imap.company.example")
        firstLaunch.updateMailEmailFromUser("renamed@company")
        firstLaunch.saveSettingsSync()

        let secondLaunch = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore()
        )
        secondLaunch.updateMailEmailFromUser("me@other-company.example")
        secondLaunch.commitMailEmailEditFromUser()

        XCTAssertEqual(secondLaunch.mailHost, "")
        XCTAssertNil(secondLaunch.credentialGuidanceHostFallback)
    }

    func testPendingDifferentRecognizedDomainCommitsBeforeConnection() async {
        let provider = FakeAppMailProvider(result: .success(()))
        let app = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: provider
        )
        app.updateMailEmailFromUser("me@company.example")
        app.updateMailHostFromUser("imap.company.example")
        app.mailAppPassword = "app-password"

        app.updateMailEmailFromUser("renamed@company")
        app.updateMailEmailFromUser("me@yahoo.com")
        await app.testConnection()

        XCTAssertEqual(provider.lastCredentials?.host, "imap.mail.yahoo.com")
        XCTAssertEqual(app.mailHost, "imap.mail.yahoo.com")
        XCTAssertNil(app.credentialGuidanceHostFallback)
    }

    private func assertPendingHostSurvivesRelaunch(_ configure: (AppState) -> Void) {
        let persistence = AppStateMemoryPersistence()
        let firstLaunch = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore()
        )
        configure(firstLaunch)
        firstLaunch.saveSettingsSync()

        let secondLaunch = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore()
        )
        secondLaunch.updateMailEmailFromUser("me@company.example")
        secondLaunch.commitMailEmailEditFromUser()

        XCTAssertEqual(secondLaunch.mailHost, "imap.gmail.com")
        XCTAssertEqual(secondLaunch.credentialGuidanceHostFallback, "imap.gmail.com")
        XCTAssertEqual(
            CredentialGuidance.forEmail(
                secondLaunch.mailEmail,
                explicitHostFallback: secondLaunch.credentialGuidanceHostFallback
            ).providerName,
            "Gmail"
        )
    }
}
