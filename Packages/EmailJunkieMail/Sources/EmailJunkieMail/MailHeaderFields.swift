import Foundation

/// A bounded set of RFC 5322 header fields fetched with
/// `BODY.PEEK[HEADER.FIELDS (...)]` — just the headers needed to judge whether a
/// message is worth replying to (item 17). ENVELOPE (from `fetchRecentMessages`)
/// gives the sender but not these list/automation/MIME content-type signals, so the
/// watcher fetches this small, targeted block before deciding to draft.
///
/// Every field is optional: absent means the server did not return that header
/// (or it was empty). Values are the raw header values with surrounding
/// whitespace trimmed and folded continuation lines unfolded into a single line.
public struct MailHeaderFields: Equatable, Sendable {
    /// `List-Id` — present on mailing-list / list-serv traffic.
    public var listID: String?
    /// `List-Unsubscribe` — present on bulk / marketing mail.
    public var listUnsubscribe: String?
    /// `Precedence` — `bulk`, `list`, or `junk` marks non-personal mail.
    public var precedence: String?
    /// `Auto-Submitted` — anything other than `no` marks automated mail
    /// (RFC 3834).
    public var autoSubmitted: String?
    /// `X-Auto-Response-Suppress` — Microsoft/Exchange marker on automated mail.
    public var autoResponseSuppress: String?
    /// `Content-Type` — used to spot calendar invites (`text/calendar`).
    public var contentType: String?
    /// MIME content types discovered from the message body structure, including
    /// nested parts. This catches invites inside multipart messages whose top-
    /// level `Content-Type` is only `multipart/*`.
    public var bodyContentTypes: [String]

    public init(
        listID: String? = nil,
        listUnsubscribe: String? = nil,
        precedence: String? = nil,
        autoSubmitted: String? = nil,
        autoResponseSuppress: String? = nil,
        contentType: String? = nil,
        bodyContentTypes: [String] = []
    ) {
        self.listID = listID
        self.listUnsubscribe = listUnsubscribe
        self.precedence = precedence
        self.autoSubmitted = autoSubmitted
        self.autoResponseSuppress = autoResponseSuppress
        self.contentType = contentType
        self.bodyContentTypes = bodyContentTypes
    }

    /// The exact header-field names requested from the server, in the order the
    /// `HEADER.FIELDS` fetch lists them.
    public static let requestedFieldNames = [
        "LIST-ID",
        "LIST-UNSUBSCRIBE",
        "PRECEDENCE",
        "AUTO-SUBMITTED",
        "X-AUTO-RESPONSE-SUPPRESS",
        "CONTENT-TYPE"
    ]

    /// Parses a raw `HEADER.FIELDS` block (field lines terminated by CRLF, with
    /// folded continuation lines beginning with whitespace) into the typed
    /// fields. Unknown fields are ignored; the last value wins for a repeated
    /// field. Robust to LF-only line endings.
    public static func parse(_ data: Data) -> MailHeaderFields {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            return MailHeaderFields()
        }
        return parse(text)
    }

    /// Parses an already-decoded header block. See `parse(_:)` above.
    public static func parse(_ text: String) -> MailHeaderFields {
        var fields = MailHeaderFields()
        for (name, value) in unfoldedHeaderLines(text) {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { continue }
            switch name.uppercased() {
            case "LIST-ID": fields.listID = trimmedValue
            case "LIST-UNSUBSCRIBE": fields.listUnsubscribe = trimmedValue
            case "PRECEDENCE": fields.precedence = trimmedValue
            case "AUTO-SUBMITTED": fields.autoSubmitted = trimmedValue
            case "X-AUTO-RESPONSE-SUPPRESS": fields.autoResponseSuppress = trimmedValue
            case "CONTENT-TYPE": fields.contentType = trimmedValue
            default: break
            }
        }
        return fields
    }

    /// Splits a header block into `(name, value)` pairs, unfolding RFC 5322
    /// continuation lines (a line beginning with a space or tab continues the
    /// previous header's value).
    private static func unfoldedHeaderLines(_ text: String) -> [(name: String, value: String)] {
        let rawLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var pairs: [(name: String, value: String)] = []
        for line in rawLines {
            if line.isEmpty { continue }
            if let first = line.first, first == " " || first == "\t" {
                // Folded continuation of the previous header value.
                guard !pairs.isEmpty else { continue }
                let continuation = line.trimmingCharacters(in: .whitespaces)
                pairs[pairs.count - 1].value += " " + continuation
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
            pairs.append((name: name, value: value))
        }
        return pairs
    }
}
