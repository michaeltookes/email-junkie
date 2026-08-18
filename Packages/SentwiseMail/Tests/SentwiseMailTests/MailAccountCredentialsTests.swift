import XCTest
@testable import SentwiseMail

final class MailAccountCredentialsTests: XCTestCase {

    func testDefaultsTargetGmail() {
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "abcd efgh ijkl mnop")
        XCTAssertEqual(credentials.host, "imap.gmail.com")
        XCTAssertEqual(credentials.port, 993)
    }

    func testNormalizedAppPasswordStripsInteriorWhitespace() {
        // Google/Yahoo/Apple all display generated passwords in grouped form.
        XCTAssertEqual(
            MailAccountCredentials.normalizedAppPassword("abcd efgh ijkl mnop"),
            "abcdefghijklmnop"
        )
    }

    func testNormalizedAppPasswordStripsEdgesTabsNewlinesAndNonBreakingSpaces() {
        // Non-breaking space (U+00A0), tab, and newline are all covered by
        // .whitespacesAndNewlines, so a copy that picked them up still works.
        XCTAssertEqual(
            MailAccountCredentials.normalizedAppPassword("  ab\u{00A0}cd\tef\ngh  "),
            "abcdefgh"
        )
    }

    func testNormalizedAppPasswordLeavesCompactPasswordsUnchanged() {
        XCTAssertEqual(
            MailAccountCredentials.normalizedAppPassword("abcdefghijklmnop"),
            "abcdefghijklmnop"
        )
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
