import XCTest
@testable import Sentwise

final class MailAccountFormStateTests: XCTestCase {

    func testEmailEditSuggestsProviderHostWithoutActiveAppState() {
        var form = MailAccountFormState()

        form.updateEmailFromUser("me@att.net")
        form.appPassword = "att-pw"

        XCTAssertEqual(form.credentials.email, "me@att.net")
        XCTAssertEqual(form.credentials.host, "imap.mail.att.net")
        XCTAssertEqual(form.credentials.appPassword, "att-pw")
        XCTAssertEqual(form.credentials.port, 993)
    }

    func testCredentialsStripInteriorWhitespaceFromPastedAppPassword() {
        var form = MailAccountFormState()

        form.updateEmailFromUser("me@gmail.com")
        // Pasted verbatim in Google's display grouping, with stray edge spaces.
        form.appPassword = "  abcd efgh ijkl mnop  "

        XCTAssertEqual(form.credentials.appPassword, "abcdefghijklmnop")
    }

    func testExplicitHostIsUsedForCredentialGuidance() {
        var form = MailAccountFormState()

        form.updateHostFromUser("imap.example.com")
        form.updateEmailFromUser("me@example.com")

        XCTAssertEqual(form.credentialGuidanceHostFallback, "imap.example.com")
        XCTAssertEqual(form.credentials.host, "imap.example.com")
    }
}
