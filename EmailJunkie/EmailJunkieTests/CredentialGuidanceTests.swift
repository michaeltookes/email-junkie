import XCTest
@testable import EmailJunkie

/// Tests for provider classification and the connect-screen credential guidance
/// (item 43). The guidance is what makes non-Gmail IMAP setup self-serve, so the
/// provider-specific copy and normal-password notes are worth pinning down.
final class CredentialGuidanceTests: XCTestCase {

    // MARK: - Provider classification

    func testClassifiesKnownProviders() {
        XCTAssertEqual(EmailProviderKind.forEmail("me@gmail.com"), .gmail)
        XCTAssertEqual(EmailProviderKind.forEmail("me@googlemail.com"), .gmail)
        XCTAssertEqual(EmailProviderKind.forEmail("me@att.net"), .att)
        XCTAssertEqual(EmailProviderKind.forEmail("me@sbcglobal.net"), .att)
        XCTAssertEqual(EmailProviderKind.forEmail("me@bellsouth.net"), .att)
        XCTAssertEqual(EmailProviderKind.forEmail("me@yahoo.com"), .yahoo)
        XCTAssertEqual(EmailProviderKind.forEmail("me@ymail.com"), .yahoo)
        XCTAssertEqual(EmailProviderKind.forEmail("me@rocketmail.com"), .yahoo)
        XCTAssertEqual(EmailProviderKind.forEmail("me@aol.com"), .aol)
        XCTAssertEqual(EmailProviderKind.forEmail("me@icloud.com"), .icloud)
        XCTAssertEqual(EmailProviderKind.forEmail("me@me.com"), .icloud)
        XCTAssertEqual(EmailProviderKind.forEmail("me@mac.com"), .icloud)
    }

    func testClassificationIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(EmailProviderKind.forEmail("  Me@ATT.net "), .att)
    }

    func testUnknownOrMalformedIsNil() {
        XCTAssertNil(EmailProviderKind.forEmail("me@example.org"))
        XCTAssertNil(EmailProviderKind.forEmail("not-an-email"))
        XCTAssertNil(EmailProviderKind.forEmail(""))
        XCTAssertNil(EmailProviderKind.forEmail("me@"))
    }

    /// Host suggestion still routes through this classifier, so the item-41
    /// hosts must be exactly preserved.
    func testHostsMatchItem41() {
        XCTAssertEqual(EmailProviderKind.gmail.imapHost, "imap.gmail.com")
        XCTAssertEqual(EmailProviderKind.att.imapHost, "imap.mail.att.net")
        XCTAssertEqual(EmailProviderKind.yahoo.imapHost, "imap.mail.yahoo.com")
        XCTAssertEqual(EmailProviderKind.aol.imapHost, "imap.aol.com")
        XCTAssertEqual(EmailProviderKind.icloud.imapHost, "imap.mail.me.com")
        XCTAssertEqual(EmailProviderKind.allHosts.count, 5)
    }

    // MARK: - Guidance content

    func testATTGuidanceUsesSecureMailKeyAndTheRightPath() {
        let guidance = CredentialGuidance.forEmail("priya@att.net")
        XCTAssertEqual(guidance.providerName, "AT&T")
        XCTAssertEqual(guidance.credentialName, "Secure Mail Key")
        XCTAssertEqual(guidance.title, "Getting your Secure Mail Key")
        XCTAssertEqual(guidance.url?.absoluteString, "https://signin.att.net")
        XCTAssertTrue(
            guidance.steps.contains { $0.contains("Manage secure mail keys") },
            "AT&T steps must name the actual menu path"
        )
        XCTAssertTrue(
            guidance.steps.contains { $0.contains("email address you entered") },
            "AT&T steps must work for att.net and legacy AT&T domains"
        )
        XCTAssertFalse(guidance.steps.contains { $0.contains("Select your att.net address") })
    }

    func testGmailGuidanceRequiresTwoStepVerification() {
        let guidance = CredentialGuidance.forEmail("me@gmail.com")
        XCTAssertEqual(guidance.credentialName, "app password")
        XCTAssertTrue(guidance.steps.contains { $0.contains("2-Step Verification") })
    }

    func testYahooAlternateDomainsUseYahooGuidance() {
        for address in ["me@yahoo.com", "me@ymail.com", "me@rocketmail.com"] {
            let guidance = CredentialGuidance.forEmail(address)
            XCTAssertEqual(guidance.providerName, "Yahoo")
            XCTAssertFalse(
                guidance.steps.contains { $0.lowercased().contains("2-step") },
                "Yahoo app-password guidance must not require enabling 2-step verification"
            )
            XCTAssertEqual(
                guidance.url?.absoluteString,
                "https://login.yahoo.com/account/security"
            )
        }
    }

    func testICloudGuidanceUsesAppSpecificPassword() {
        let guidance = CredentialGuidance.forEmail("me@icloud.com")
        XCTAssertEqual(guidance.credentialName, "app-specific password")
        XCTAssertEqual(guidance.url?.absoluteString, "https://appleid.apple.com")
        XCTAssertTrue(
            guidance.steps.contains { $0.contains("two-factor authentication") },
            "iCloud guidance must name the prerequisite for app-specific passwords"
        )
    }

    /// The single most-missed fact — the normal password won't work — must be
    /// present for every provider, grammatically correct.
    func testEveryProviderWarnsThatTheNormalPasswordWontWork() {
        for kind in EmailProviderKind.allCases {
            let guidance = CredentialGuidance.forKind(kind)
            XCTAssertTrue(
                guidance.passwordWontWorkNote.contains("won't work"),
                "\(kind) guidance must warn the normal password won't work"
            )
        }
        // Correct article for a vowel-initial credential name.
        XCTAssertTrue(
            CredentialGuidance.forKind(.icloud).passwordWontWorkNote.contains("an app-specific password")
        )
        XCTAssertTrue(
            CredentialGuidance.forKind(.att).passwordWontWorkNote.contains("a Secure Mail Key")
        )
    }

    // MARK: - Generic fallback

    /// An unrecognized domain must still get usable, non-Gmail-specific advice
    /// without claiming that every provider rejects normal-password IMAP auth.
    func testUnknownProviderGetsGenericGuidance() {
        let guidance = CredentialGuidance.forEmail("me@fastmail.com")
        XCTAssertEqual(guidance, CredentialGuidance.generic)
        XCTAssertNil(guidance.url)
        XCTAssertEqual(guidance.title, "Getting your IMAP sign-in credential")
        XCTAssertTrue(guidance.steps.contains { $0.contains("secure mail key") })
        XCTAssertTrue(guidance.passwordWontWorkNote.contains("some accept your normal email password"))
        XCTAssertFalse(guidance.passwordWontWorkNote.contains("won't work here"))
        XCTAssertFalse(
            guidance.passwordWontWorkNote.contains("Gmail"),
            "generic guidance must not be Gmail-specific"
        )
    }

    func testEmptyEmailGetsGenericGuidanceNotACrash() {
        XCTAssertEqual(CredentialGuidance.forEmail(""), CredentialGuidance.generic)
    }
}
