import Foundation

/// Best-effort reduction of a raw IMAP text body (`BODY[TEXT]`) to human-readable
/// plain text — the form the voice profile and draft prompts want.
///
/// Handles the common shapes seen in real mail: single-part text, multipart
/// (`multipart/alternative` and friends) with per-part `Content-Transfer-Encoding`,
/// quoted-printable and base64 decoding, and a plain-text fallback that strips
/// tags from an HTML-only body. It is intentionally lenient: anything it can't
/// confidently parse is returned as-is rather than dropped.
///
/// Known limitation: `BODY[TEXT]` omits the message's top-level headers, so a
/// *single-part* body whose transfer encoding is declared only in those headers
/// cannot be decoded here. The efficient long-term path is a `BODYSTRUCTURE`-
/// guided fetch of just the `text/plain` part (tracked in the backlog).
public enum MailBodyText {

    /// Reduces a raw text body to readable plain text.
    public static func plainText(from raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if let boundary = topBoundary(of: normalized),
           let text = text(fromMultipart: normalized, boundary: boundary) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeHTML(trimmed) {
            return strippingHTML(trimmed)
        }
        return trimmed
    }

    // MARK: - Multipart

    /// The boundary of a multipart body, detected by scanning past any MIME
    /// preamble to a repeated delimiter.
    private static func topBoundary(of body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for candidate in lines where candidate.hasPrefix("--") && candidate.count > 2 {
            let boundary = String(candidate.dropFirst(2))
            let delimiter = "--" + boundary
            let closing = delimiter + "--"
            let occurrences = lines.filter { $0 == delimiter || $0 == closing }.count
            if occurrences >= 2 { return boundary }
        }
        return nil
    }

    /// Extracts readable text from a multipart body: prefers a `text/plain`
    /// part, falls back to a tag-stripped `text/html` part, and recurses into
    /// nested multiparts.
    private static func text(fromMultipart body: String, boundary: String) -> String? {
        let parts = parts(fromMultipart: body, boundary: boundary)
        var htmlFallback: String?
        var hasBlankPlainPart = false

        for part in parts {
            if let text = text(
                fromPart: part,
                htmlFallback: &htmlFallback,
                hasBlankPlainPart: &hasBlankPlainPart
            ) {
                return text
            }
        }
        return htmlFallback ?? (hasBlankPlainPart ? "" : nil)
    }

    private static func parts(fromMultipart body: String, boundary: String) -> [[String]] {
        let delimiter = "--" + boundary
        let closing = delimiter + "--"
        var parts: [[String]] = []
        var current: [String]?

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == closing {
                if let cur = current { parts.append(cur) }
                current = nil
            } else if trimmed == delimiter {
                if let cur = current { parts.append(cur) }
                current = []
            } else {
                current?.append(line)
            }
        }
        if let cur = current { parts.append(cur) }

        return parts
    }

    private static func text(
        fromPart part: [String],
        htmlFallback: inout String?,
        hasBlankPlainPart: inout Bool
    ) -> String? {
        let (headers, content) = split(part)
        let contentType = (headers["content-type"] ?? "text/plain").lowercased()

        if contentType.hasPrefix("multipart/"), let nested = boundaryParameter(headers["content-type"]) {
            guard let nestedText = text(fromMultipart: content, boundary: nested) else {
                return nil
            }
            if nestedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasBlankPlainPart = true
                return nil
            }
            return nestedText
        }

        let decoded = decode(content, encoding: headers["content-transfer-encoding"]?.lowercased())
        if contentType.hasPrefix("text/plain") {
            if decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasBlankPlainPart = true
                return nil
            }
            return decoded
        }
        if contentType.hasPrefix("text/html"), htmlFallback == nil {
            htmlFallback = strippingHTML(decoded)
        }
        return nil
    }

    /// Splits a MIME part into its header map and body content.
    private static func split(_ lines: [String]) -> (headers: [String: String], body: String) {
        var headers: [String: String] = [:]
        var currentKey: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }

            if isHeaderContinuation(line), let key = currentKey {
                let continuation = line.trimmingCharacters(in: .whitespaces)
                if let existing = headers[key], !existing.isEmpty {
                    headers[key] = existing + " " + continuation
                } else {
                    headers[key] = continuation
                }
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
            currentKey = key
        }
        let body = index < lines.count ? lines[index...].joined(separator: "\n") : ""
        return (headers, body)
    }

    private static func isHeaderContinuation(_ line: String) -> Bool {
        guard let first = line.unicodeScalars.first else { return false }
        return first == " " || first == "\t"
    }

    /// Extracts the `boundary=` parameter from a `Content-Type` value.
    private static func boundaryParameter(_ contentType: String?) -> String? {
        guard let contentType, let range = contentType.range(of: "boundary=", options: .caseInsensitive) else {
            return nil
        }
        var value = String(contentType[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") { value = String(value[..<end]) }
        } else if let end = value.firstIndex(of: ";") {
            value = String(value[..<end]).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? nil : value
    }

    // MARK: - Transfer encodings

    private static func decode(_ content: String, encoding: String?) -> String {
        switch encoding {
        case "quoted-printable":
            return decodeQuotedPrintable(content)
        case "base64":
            let stripped = content.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: stripped), let text = String(data: data, encoding: .utf8) {
                return text
            }
            return content
        default:
            return content
        }
    }

    private static func decodeQuotedPrintable(_ content: String) -> String {
        // Join soft line breaks ("=" at end of line), then decode "=XX" bytes.
        let joined = content.replacingOccurrences(of: "=\n", with: "")
        let chars = Array(joined.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < chars.count {
            if chars[index] == UInt8(ascii: "="), index + 2 < chars.count {
                let hex = String(bytes: chars[(index + 1)...(index + 2)], encoding: .ascii) ?? ""
                if let byte = UInt8(hex, radix: 16) {
                    bytes.append(byte)
                    index += 3
                    continue
                }
            }
            bytes.append(chars[index])
            index += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? joined
    }

    // MARK: - HTML

    private static func looksLikeHTML(_ text: String) -> Bool {
        text.range(
            of: #"<!doctype\s+html\b|<\s*(html|head|body|style|script|p|div|br|table|span|a|blockquote)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func strippingHTML(_ html: String) -> String {
        var text = html
        // Drop script/style blocks wholesale before removing remaining tags.
        for tag in ["script", "style"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Turn block-level boundaries into line breaks before dropping tags, so
        // paragraphs don't run together into one line.
        text = text.replacingOccurrences(
            of: "<br\\s*/?>|</(p|div|tr|li|h[1-6]|blockquote)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}
