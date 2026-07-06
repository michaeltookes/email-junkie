import XCTest
@testable import EmailJunkieMail

/// Pure, server-free coverage of `MailBodyText.plainText(from:)` — the reduction
/// of raw MIME bodies to readable text for voice profiling and drafting.
final class MailBodyTextTests: XCTestCase {

    func testSinglePartPlainTextIsReturnedTrimmed() {
        let raw = "\r\nHi Alice,\r\n\r\nThanks for the note.\r\n\r\n— Me\r\n\r\n"
        XCTAssertEqual(
            MailBodyText.plainText(from: raw),
            "Hi Alice,\n\nThanks for the note.\n\n— Me"
        )
    }

    func testMultipartAlternativePrefersPlainText() {
        let raw = [
            "--BOUND",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Plain version here.",
            "--BOUND",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<html><body><p>HTML version here.</p></body></html>",
            "--BOUND--"
        ].joined(separator: "\r\n")

        XCTAssertEqual(MailBodyText.plainText(from: raw), "Plain version here.")
    }

    func testMultipartPreambleIsSkippedBeforeBoundaryDetection() {
        let raw = [
            "This is a multi-part message in MIME format.",
            "",
            "--BOUND",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Readable body here.",
            "--BOUND",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<html><body><p>HTML version here.</p></body></html>",
            "--BOUND--"
        ].joined(separator: "\r\n")

        XCTAssertEqual(MailBodyText.plainText(from: raw), "Readable body here.")
    }

    func testDecodesQuotedPrintablePart() {
        let raw = [
            "--BOUND",
            "Content-Type: text/plain",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "Caf=C3=A9 pric=\r\ning is =E2=82=AC5.",
            "--BOUND--"
        ].joined(separator: "\r\n")

        XCTAssertEqual(MailBodyText.plainText(from: raw), "Café pricing is €5.")
    }

    func testDecodesBase64Part() {
        let encoded = Data("Hello from base64.".utf8).base64EncodedString()
        let raw = [
            "--BOUND",
            "Content-Type: text/plain",
            "Content-Transfer-Encoding: base64",
            "",
            encoded,
            "--BOUND--"
        ].joined(separator: "\r\n")

        XCTAssertEqual(MailBodyText.plainText(from: raw), "Hello from base64.")
    }

    func testFallsBackToStrippedHTMLWhenNoPlainPart() {
        let raw = [
            "--BOUND",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<html><head><style>p{color:red}</style></head>"
                + "<body><p>Hello&nbsp;there</p><p>Second line</p></body></html>",
            "--BOUND--"
        ].joined(separator: "\r\n")

        XCTAssertEqual(MailBodyText.plainText(from: raw), "Hello there\nSecond line")
    }

    func testRecursesIntoNestedMultipart() {
        let raw = [
            "--OUTER",
            "Content-Type: multipart/alternative; boundary=\"INNER\"",
            "",
            "--INNER",
            "Content-Type: text/plain",
            "",
            "Nested plain body.",
            "--INNER--",
            "--OUTER--"
        ].joined(separator: "\r\n")

        XCTAssertEqual(MailBodyText.plainText(from: raw), "Nested plain body.")
    }

    func testPlainBodyWithSignatureDashesIsNotTreatedAsMultipart() {
        // A "-- " signature delimiter must not be mistaken for a MIME boundary.
        let raw = "See you then.\r\n\r\n-- \r\nMichael"
        XCTAssertEqual(MailBodyText.plainText(from: raw), "See you then.\n\n-- \nMichael")
    }
}
