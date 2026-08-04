import XCTest
@testable import EmailJunkie

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

    func testExplicitHostIsUsedForCredentialGuidance() {
        var form = MailAccountFormState()

        form.updateHostFromUser("imap.example.com")
        form.updateEmailFromUser("me@example.com")

        XCTAssertEqual(form.credentialGuidanceHostFallback, "imap.example.com")
        XCTAssertEqual(form.credentials.host, "imap.example.com")
    }
}
