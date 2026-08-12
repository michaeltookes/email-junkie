import Foundation

/// Turns raw transcript file contents into speaker-preserving plain text
/// (item 51). Pure and side-effect-free so it is fully unit-testable against
/// messy real-world exports.
///
/// - Plain text / Markdown pass through with whitespace normalized.
/// - WebVTT and SubRip cue blocks have their cue numbers and `-->` timestamps
///   stripped; WebVTT `<v Name>` voice tags become `Name:` speaker prefixes and
///   all other angle-bracket tags are removed.
enum TranscriptParser {

    /// Parses `raw` according to `format`.
    static func parse(_ raw: String, format: TranscriptFormat) -> ParsedTranscript {
        switch format {
        case .plainText, .markdown:
            return parsePlainText(raw)
        case .webVTT:
            return parseCueBased(raw, isWebVTT: true)
        case .subRip:
            return parseCueBased(raw, isWebVTT: false)
        }
    }

    // MARK: - Plain text

    private static func parsePlainText(_ raw: String) -> ParsedTranscript {
        let lines = normalizedLines(raw)
        let collapsed = collapseBlankRuns(lines)
        let text = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTranscript(text: text, hasSpeakerLabels: containsSpeakerLabel(collapsed))
    }

    // MARK: - Cue-based (WebVTT / SubRip)

    private static func parseCueBased(_ raw: String, isWebVTT: Bool) -> ParsedTranscript {
        let lines = normalizedLines(raw)
        var output: [String] = []
        var sawVoiceTag = false
        var skippingMetadataBlock = false

        for (offset, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                skippingMetadataBlock = false
                continue
            }
            if isWebVTT, isWebVTTMetadata(trimmed) {
                // WEBVTT header and NOTE/STYLE/REGION blocks run until a blank line.
                skippingMetadataBlock = trimmed.hasPrefix("WEBVTT") || trimmed.hasPrefix("NOTE")
                    || trimmed.hasPrefix("STYLE") || trimmed.hasPrefix("REGION")
                continue
            }
            if skippingMetadataBlock { continue }
            if trimmed.contains("-->") { continue }
            if isCueIdentifier(trimmed, isWebVTT: isWebVTT, immediatelyFollowedBy: immediateLine(in: lines, after: offset)) {
                continue
            }
            let cleaned = cleanedCueText(trimmed, isWebVTT: isWebVTT, sawVoiceTag: &sawVoiceTag)
            if !cleaned.isEmpty { output.append(cleaned) }
        }

        let deduped = collapseConsecutiveDuplicates(output)
        let text = deduped.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLabels = sawVoiceTag || containsSpeakerLabel(deduped)
        return ParsedTranscript(text: text, hasSpeakerLabels: hasLabels)
    }

    private static func isWebVTTMetadata(_ trimmed: String) -> Bool {
        trimmed == "WEBVTT" || trimmed.hasPrefix("WEBVTT")
            || trimmed.hasPrefix("NOTE") || trimmed.hasPrefix("STYLE")
            || trimmed.hasPrefix("REGION") || trimmed.hasPrefix("X-TIMESTAMP-MAP")
    }

    /// A cue identifier is a bare integer (SubRip index or numeric WebVTT id), or a
    /// single-token WebVTT id line whose *immediately* following line is the cue's
    /// timestamp. The immediacy check matters: a one-word caption ("Hello") is
    /// separated from the next cue's timestamp by a blank line, so it is not
    /// mistaken for an identifier.
    private static func isCueIdentifier(_ trimmed: String, isWebVTT: Bool, immediatelyFollowedBy next: String?) -> Bool {
        if isAllDigits(trimmed) { return true }
        guard isWebVTT, let next, next.contains("-->") else { return false }
        return !trimmed.contains(":") && !trimmed.contains(" ")
    }

    /// Converts a WebVTT `<v Name>` voice tag into a `Name:` prefix and strips all
    /// remaining angle-bracket tags. SubRip text only has its tags stripped.
    private static func cleanedCueText(_ line: String, isWebVTT: Bool, sawVoiceTag: inout Bool) -> String {
        var text = line
        if isWebVTT, let voice = extractVoiceTag(text) {
            sawVoiceTag = true
            text = "\(voice.name): \(voice.remainder)"
        }
        text = stripAngleTags(text)
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Shared helpers

    private static func normalizedLines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func collapseBlankRuns(_ lines: [String]) -> [String] {
        var result: [String] = []
        var previousBlank = false
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank && previousBlank { continue }
            result.append(isBlank ? "" : line)
            previousBlank = isBlank
        }
        return result
    }

    private static func collapseConsecutiveDuplicates(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines where line != result.last {
            result.append(line)
        }
        return result
    }

    /// The line immediately after `index` (no blank-line skipping), trimmed, or
    /// `nil` at end of input. Used to tell a cue identifier (whose very next line
    /// is the timestamp) from a one-word caption (separated by a blank line).
    private static func immediateLine(in lines: [String], after index: Int) -> String? {
        let next = index + 1
        guard next < lines.count else { return nil }
        return lines[next].trimmingCharacters(in: .whitespaces)
    }

    private static func isAllDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isNumber }
    }

    private static func stripAngleTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        let stripped = text.replacingOccurrences(
            of: "<[^>]*>",
            with: "",
            options: .regularExpression
        )
        return stripped
    }

    private static func extractVoiceTag(_ text: String) -> (name: String, remainder: String)? {
        guard let range = text.range(
            of: "<v(?:\\.[^ >]+)*\\s+([^>]*)>",
            options: .regularExpression
        ) else { return nil }
        var inner = String(text[range])
        inner.removeFirst(2)   // drop "<v"
        inner.removeLast()     // drop ">"
        inner = inner.trimmingCharacters(in: .whitespaces)
        // `inner` is either "Name" or a ".class.tokens Name" styling group.
        let name = inner.hasPrefix(".")
            ? inner.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? inner
            : inner
        var remainder = text
        remainder.replaceSubrange(range, with: "")
        remainder = remainder
            .replacingOccurrences(of: "</v>", with: "")
            .trimmingCharacters(in: .whitespaces)
        return (name, remainder)
    }

    /// Whether any line looks like `Speaker Name: said something` — the label
    /// convention notetakers use when they don't have structured voice tags.
    static func containsSpeakerLabel(_ lines: [String]) -> Bool {
        lines.contains { lineHasSpeakerLabel($0) }
    }

    static func lineHasSpeakerLabel(_ line: String) -> Bool {
        line.range(
            of: "^\\s*[\\p{L}][\\p{L}0-9 .'’\\-]{0,39}:\\s",
            options: .regularExpression
        ) != nil
    }
}
