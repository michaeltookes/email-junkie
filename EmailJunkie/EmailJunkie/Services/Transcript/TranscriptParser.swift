import Foundation

/// Turns raw transcript file contents into speaker-preserving plain text
/// (item 51). Pure and side-effect-free so it is fully unit-testable against
/// messy real-world exports.
///
/// - Plain text / Markdown pass through with whitespace normalized.
/// - WebVTT and SubRip cue blocks have their cue numbers and `-->` timestamps
///   stripped; WebVTT `<v Name>` voice tags become `Name:` speaker prefixes and
///   recognized caption formatting tags are removed.
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
        var isInCuePayload = false

        for (offset, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                skippingMetadataBlock = false
                isInCuePayload = false
                continue
            }
            if skippingMetadataBlock { continue }
            if isWebVTT, !isInCuePayload, let metadataSkipsUntilBlank = webVTTMetadata(trimmed) {
                // WEBVTT header and NOTE/STYLE/REGION blocks run until a blank line.
                skippingMetadataBlock = metadataSkipsUntilBlank
                continue
            }
            if !isInCuePayload, isCueTimingLine(trimmed, isWebVTT: isWebVTT) {
                isInCuePayload = true
                continue
            }
            if !isInCuePayload,
               isCueIdentifier(trimmed, isWebVTT: isWebVTT, immediatelyFollowedBy: immediateLine(in: lines, after: offset)) {
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

    private static func webVTTMetadata(_ trimmed: String) -> Bool? {
        if matchesKeyword(trimmed, "WEBVTT", allowsWhitespaceSuffix: true) {
            return true
        }
        if matchesKeyword(trimmed, "NOTE", allowsWhitespaceSuffix: true) {
            return true
        }
        if trimmed == "STYLE" || trimmed == "REGION" {
            return true
        }
        if trimmed == "X-TIMESTAMP-MAP" || trimmed.hasPrefix("X-TIMESTAMP-MAP=") {
            return false
        }
        return nil
    }

    private static func matchesKeyword(
        _ trimmed: String,
        _ keyword: String,
        allowsWhitespaceSuffix: Bool
    ) -> Bool {
        guard trimmed.hasPrefix(keyword) else { return false }
        guard trimmed.count > keyword.count else { return true }
        guard allowsWhitespaceSuffix else { return false }
        let suffixStart = trimmed.index(trimmed.startIndex, offsetBy: keyword.count)
        return trimmed[suffixStart].unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    /// A cue identifier is a bare integer (SubRip index or numeric WebVTT id), or a
    /// single-token WebVTT id line, only when the *immediately* following line is
    /// the cue's timestamp. The immediacy check matters: one-word or numeric
    /// captions are separated from the next cue's timestamp by a blank line, so they
    /// are not mistaken for identifiers.
    private static func isCueIdentifier(_ trimmed: String, isWebVTT: Bool, immediatelyFollowedBy next: String?) -> Bool {
        if isAllDigits(trimmed) {
            guard let next else { return false }
            return isCueTimingLine(next, isWebVTT: isWebVTT)
        }
        guard isWebVTT, let next, isCueTimingLine(next, isWebVTT: true) else { return false }
        return !trimmed.contains(":") && !trimmed.contains(" ")
    }

    private static func isCueTimingLine(_ line: String, isWebVTT: Bool) -> Bool {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return false }
        let start = parts[0].trimmingCharacters(in: .whitespaces)
        let endAndSettings = parts[1].trimmingCharacters(in: .whitespaces)
        guard let end = endAndSettings.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return false
        }
        return isTimestamp(start, isWebVTT: isWebVTT)
            && isTimestamp(String(end), isWebVTT: isWebVTT)
    }

    private static func isTimestamp(_ token: String, isWebVTT: Bool) -> Bool {
        let pattern = isWebVTT
            ? #"^(?:\d{2,}:)?[0-5]\d:[0-5]\d\.\d{3}$"#
            : #"^\d{2,}:[0-5]\d:[0-5]\d,\d{3}$"#
        return token.range(of: pattern, options: .regularExpression) != nil
    }

    /// Converts a WebVTT `<v Name>` voice tag into a `Name:` prefix and strips
    /// recognized caption tags. Literal angle-bracket text is preserved.
    private static func cleanedCueText(_ line: String, isWebVTT: Bool, sawVoiceTag: inout Bool) -> String {
        var text = line
        if isWebVTT {
            let voiceSpans = extractCompleteVoiceSpans(text)
            if voiceSpans.count > 1 {
                sawVoiceTag = true
                return voiceSpans
                    .map { "\($0.name): \($0.text)" }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        if isWebVTT, let voice = extractVoiceTag(text) {
            sawVoiceTag = true
            text = "\(voice.name): \(voice.remainder)"
        }
        text = stripCaptionTags(text)
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

    private static func stripCaptionTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return [
            #"<(?:\d{2,}:)?[0-5]\d:[0-5]\d\.\d{3}>"#,
            #"</?(?:b|i|u|ruby|rt)(?:\s+[^>]*)?>"#,
            #"</?c(?:\.[^ >]+)*(?:\s+[^>]*)?>"#,
            #"</?lang(?:\s+[^>]*)?>"#,
            #"</?v(?:\.[^ >]+)*(?:\s+[^>]*)?>"#,
            #"</?font(?:\s+[^>]*)?>"#
        ].reduce(text) { partial, pattern in
            partial.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    private static func extractCompleteVoiceSpans(_ text: String) -> [(name: String, text: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<v(?:\.[^ >]+)*\s+([^>]*)>(.*?)</v>"#
        ) else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let cueTextRange = Range(match.range(at: 2), in: text) else {
                return nil
            }
            let name = normalizedVoiceName(String(text[nameRange]))
            let cueText = stripCaptionTags(String(text[cueTextRange]))
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !cueText.isEmpty else { return nil }
            return (name: name, text: cueText)
        }
    }

    private static func extractVoiceTag(_ text: String) -> (name: String, remainder: String)? {
        guard let range = text.range(
            of: "<v(?:\\.[^ >]+)*\\s+([^>]*)>",
            options: .regularExpression
        ) else { return nil }
        var inner = String(text[range])
        inner.removeFirst(2)   // drop "<v"
        inner.removeLast()     // drop ">"
        let name = normalizedVoiceName(inner)
        var remainder = text
        remainder.replaceSubrange(range, with: "")
        remainder = remainder
            .replacingOccurrences(of: "</v>", with: "")
            .trimmingCharacters(in: .whitespaces)
        return (name, remainder)
    }

    private static func normalizedVoiceName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // `trimmed` is either "Name" or a ".class.tokens Name" styling group.
        return trimmed.hasPrefix(".")
            ? trimmed.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? trimmed
            : trimmed
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
