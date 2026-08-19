import XCTest
@testable import SentwiseMail

final class MailAccountCredentialsTests: XCTestCase {

    func testDefaultsTargetGmail() {
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "abcd efgh ijkl mnop")
        XCTAssertEqual(credentials.host, "imap.gmail.com")
        XCTAssertEqual(credentials.port, 993)
    }

    func testNormalizedGroupedAppPasswordStripsInteriorWhitespace() {
        // Google/Yahoo/Apple all display generated passwords in grouped form.
        XCTAssertEqual(
            MailAccountCredentials.normalizedGroupedAppPassword("abcd efgh ijkl mnop"),
            "abcdefghijklmnop"
        )
    }

    func testNormalizedGroupedAppPasswordStripsEdgesTabsNewlinesAndNonBreakingSpaces() {
        // Non-breaking space (U+00A0), tab, and newline are all covered by
        // .whitespacesAndNewlines, so a copy that picked them up still works.
        XCTAssertEqual(
            MailAccountCredentials.normalizedGroupedAppPassword("  ab\u{00A0}cd\tef\ngh  "),
            "abcdefgh"
        )
    }

    func testNormalizedGroupedAppPasswordLeavesCompactPasswordsUnchanged() {
        XCTAssertEqual(
            MailAccountCredentials.normalizedGroupedAppPassword("abcdefghijklmnop"),
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
