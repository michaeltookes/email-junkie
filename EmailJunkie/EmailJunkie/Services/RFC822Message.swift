import Foundation

/// Builds an RFC 5322 message to append to the Drafts mailbox (or send later).
///
/// Pure and deterministic — the caller injects the date and Message-ID so the
/// output is fully unit-testable. The body is base64-encoded (UTF-8) so any
/// content is transmitted safely; a non-ASCII subject is RFC 2047 encoded.
struct OutgoingMessage: Equatable {
    var from: String
    var to: [String]
    var subject: String
    var body: String
    var date: Date
    var messageID: String
    var inReplyTo: String?
    var references: [String]

    /// Renders the message as RFC 5322 bytes with CRLF line endings.
    func rfc822() -> Data {
        var headers: [String] = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))",
            "Subject: \(Self.encodedSubject(subject))",
            "Date: \(Self.rfc822Date(date))",
            "Message-ID: \(messageID)"
        ]
        if let inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
        }
        let refs = references.filter { !$0.isEmpty }
        if !refs.isEmpty {
            headers.append("References: \(refs.joined(separator: " "))")
        }
        headers.append("MIME-Version: 1.0")
        headers.append("Content-Type: text/plain; charset=utf-8")
        headers.append("Content-Transfer-Encoding: base64")

        let encodedBody = Data(body.utf8).base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        )
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody + "\r\n"
        return Data(message.utf8)
    }

    // MARK: - Helpers

    /// RFC 2047 encoded-word for non-ASCII subjects; plain otherwise.
    static func encodedSubject(_ subject: String) -> String {
        guard subject.contains(where: { !$0.isASCII }) else { return subject }
        let encoded = Data(subject.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    /// RFC 5322 date, e.g. `Tue, 07 Jul 2026 13:00:00 +0000`.
    static func rfc822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
