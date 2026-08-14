import Foundation

/// An incoming reply split into what the sender just wrote and the quoted
/// history of the earlier conversation beneath it.
struct EmailThread: Equatable {
    /// The sender's freshly-written text — the message to actually reply to.
    var latest: String
    /// The quoted prior conversation below the fresh text (markers preserved),
    /// empty when the message carries no quoted history.
    var quotedHistory: String
}

/// Splits a plain-text email body into its fresh reply and quoted history at the
/// first quoted-reply marker.
///
/// Pure and unit-tested; shared by the draft engine (which feeds the history to
/// the model as thread context) and voice profiling (which keeps only the
/// fresh text as a writing sample).
enum EmailThreadParser {

    /// Whether a trimmed line begins the quoted history: a `>` quote prefix, an
    /// Outlook `-----Original Message-----` separator, or a Gmail/Apple
    /// `On <date> <person> wrote:` attribution line.
    static func isQuoteMarker(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix(">")
            || trimmedLine.hasPrefix("-----Original Message-----")
            || trimmedLine.range(of: #"^On .+wrote:$"#, options: .regularExpression) != nil
    }

    /// Splits `body` at the first quote marker. Everything before it is the
    /// fresh reply; the marker line and everything after is the quoted history.
    /// A body with no marker is returned entirely as `latest`.
    static func split(_ body: String) -> EmailThread {
        let lines = body.components(separatedBy: "\n")
        var latest: [String] = []
        var historyStart: Int?
        for (index, line) in lines.enumerated() {
            if isQuoteMarker(line.trimmingCharacters(in: .whitespaces)) {
                historyStart = index
                break
            }
            latest.append(line)
        }
        let history = historyStart.map { lines[$0...].joined(separator: "\n") } ?? ""
        return EmailThread(latest: latest.joined(separator: "\n"), quotedHistory: history)
    }

    /// A readable, bounded form of already-split quoted history for prompt
    /// context: leading `>` markers stripped so it reads as prose, surrounding
    /// whitespace trimmed, and capped at `maxChars`. Empty in, empty out.
    static func readableHistory(fromQuoted quotedHistory: String, maxChars: Int) -> String {
        guard !quotedHistory.isEmpty else { return "" }
        let dequoted = quotedHistory
            .components(separatedBy: "\n")
            .map(stripQuoteMarkers)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(dequoted.prefix(maxChars))
    }

    /// Removes leading whitespace and `>` quote markers (each with one optional
    /// following space) from a single line.
    private static func stripQuoteMarkers(_ line: String) -> String {
        var slice = Substring(line)
        while let first = slice.first, first == " " || first == "\t" {
            slice = slice.dropFirst()
        }
        while slice.first == ">" {
            slice = slice.dropFirst()
            if slice.first == " " { slice = slice.dropFirst() }
        }
        return String(slice)
    }
}
