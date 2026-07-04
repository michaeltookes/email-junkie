import XCTest
@testable import EmailJunkieMail

final class MailAccountCredentialsTests: XCTestCase {

    func testDefaultsTargetGmail() {
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "abcd efgh ijkl mnop")
        XCTAssertEqual(credentials.host, "imap.gmail.com")
        XCTAssertEqual(credentials.port, 993)
    }

    func testIsCompleteRequiresAllFields() {
        XCTAssertTrue(
            MailAccountCredentials(email: "me@gmail.com", appPassword: "pw").isComplete
        )
        XCTAssertFalse(
            MailAccountCredentials(email: "", appPassword: "pw").isComplete
        )
        XCTAssertFalse(
            MailAccountCredentials(email: "me@gmail.com", appPassword: "").isComplete
        )
        XCTAssertFalse(
            MailAccountCredentials(email: "me@gmail.com", appPassword: "pw", host: "", port: 993).isComplete
        )
        XCTAssertFalse(
            MailAccountCredentials(email: "me@gmail.com", appPassword: "pw", port: 0).isComplete
        )
    }
}
