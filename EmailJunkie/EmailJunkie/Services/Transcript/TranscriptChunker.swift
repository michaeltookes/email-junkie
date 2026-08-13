import Foundation

/// Splits a long transcript into context-window-sized chunks (item 51), breaking
/// on line boundaries (speaker turns) so a chunk never cuts a sentence unless a
/// single line is itself larger than the limit. Pure and unit-testable.
enum TranscriptChunker {

    /// Splits `text` into chunks no longer than `maxChars`. Returns a single chunk
    /// (or none, for empty input) when the text already fits.
    static func chunk(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxChars > 0 else { return trimmed.isEmpty ? [] : [trimmed] }
        guard trimmed.count > maxChars else { return trimmed.isEmpty ? [] : [trimmed] }

        var chunks: [String] = []
        var current = ""
        for line in trimmed.components(separatedBy: "\n") {
            if line.count > maxChars {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSplit(line, maxChars: maxChars))
                continue
            }
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.count > maxChars {
                if !current.isEmpty { chunks.append(current) }
                current = line
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Breaks a single over-long line into fixed-size character windows.
    private static func hardSplit(_ line: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var index = line.startIndex
        while index < line.endIndex {
            let end = line.index(index, offsetBy: maxChars, limitedBy: line.endIndex) ?? line.endIndex
            pieces.append(String(line[index..<end]))
            index = end
        }
        return pieces
    }
}
