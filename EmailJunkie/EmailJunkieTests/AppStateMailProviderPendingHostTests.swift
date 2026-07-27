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

        XCTAssertEqual(secondLaunch.mailHost, "")
        XCTAssertNil(secondLaunch.credentialGuidanceHostFallback)
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
