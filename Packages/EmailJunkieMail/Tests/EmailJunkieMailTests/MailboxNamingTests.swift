import XCTest
@testable import EmailJunkieMail

final class MailboxNamingTests: XCTestCase {

    // MARK: - forHost

    func testGmailHostsResolveToGmailLayout() {
        XCTAssertEqual(MailboxNaming.forHost("imap.gmail.com"), .gmail)
        XCTAssertEqual(MailboxNaming.forHost("imap.googlemail.com"), .gmail)
        XCTAssertEqual(MailboxNaming.forHost("IMAP.GMAIL.COM"), .gmail, "case-insensitive")
    }

    func testYahooAndAttHostsResolveToYahooLayout() {
        XCTAssertEqual(MailboxNaming.forHost("imap.mail.yahoo.com"), .yahoo)
        XCTAssertEqual(MailboxNaming.forHost("imap.mail.att.net"), .yahoo)
        XCTAssertEqual(MailboxNaming.forHost("imap.aol.com"), .yahoo)
    }

    func testUnknownHostResolvesToGenericLayout() {
        XCTAssertEqual(MailboxNaming.forHost("imap.fastmail.com"), .generic)
        XCTAssertEqual(MailboxNaming.forHost("mail.example.org"), .generic)
    }

    // MARK: - allMail support

    func testGmailSupportsAllMailButYahooDoesNot() {
        XCTAssertTrue(MailboxNaming.gmail.supportsAllMail)
        XCTAssertFalse(MailboxNaming.yahoo.supportsAllMail)
        XCTAssertFalse(MailboxNaming.generic.supportsAllMail)
    }

    // MARK: - Mailbox.imapName(using:)

    func testResolvesSpecialFoldersPerProvider() {
        XCTAssertEqual(Mailbox.sent.imapName(using: .gmail), "[Gmail]/Sent Mail")
        XCTAssertEqual(Mailbox.sent.imapName(using: .yahoo), "Sent")
        XCTAssertEqual(Mailbox.drafts.imapName(using: .yahoo), "Draft")
        XCTAssertEqual(Mailbox.drafts.imapName(using: .generic), "Drafts")
    }

    func testInboxAndNamedAreProviderIndependent() {
        XCTAssertEqual(Mailbox.inbox.imapName(using: .yahoo), "INBOX")
        XCTAssertEqual(Mailbox.named("Archive/2026").imapName(using: .gmail), "Archive/2026")
    }

    func testAllMailFallsBackToInboxWhenProviderHasNone() {
        XCTAssertEqual(Mailbox.allMail.imapName(using: .gmail), "[Gmail]/All Mail")
        XCTAssertEqual(Mailbox.allMail.imapName(using: .yahoo), "INBOX", "no all-mail on Yahoo → INBOX")
    }

    // MARK: - credentials integration

    func testCredentialsDeriveNamingFromHost() {
        let att = MailAccountCredentials(email: "me@att.net", appPassword: "x", host: "imap.mail.att.net")
        XCTAssertEqual(att.mailboxNaming, .yahoo)
        let gmail = MailAccountCredentials(email: "me@gmail.com", appPassword: "x")
        XCTAssertEqual(gmail.mailboxNaming, .gmail)
    }
}
