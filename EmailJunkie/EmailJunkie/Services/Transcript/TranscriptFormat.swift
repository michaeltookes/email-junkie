import Foundation

/// A transcript file format the app can ingest (item 51). Zoom, Teams, and
/// third-party notetakers export one of these; adding a new format is a matter
/// of adding a case here plus a branch in `TranscriptParser`.
enum TranscriptFormat: String, CaseIterable, Equatable {
    /// Plain `.txt` — one speaker turn per line, or free-form notes.
    case plainText
    /// Markdown `.md` — treated like plain text; markup is left intact for the LLM.
    case markdown
    /// WebVTT `.vtt` — cue blocks with `-->` timestamps and optional `<v Name>` voice tags.
    case webVTT
    /// SubRip `.srt` — numbered cue blocks with `-->` timestamps.
    case subRip

    /// Lower-cased file extensions accepted by the file/drag-and-drop importer and
    /// the watched-folder source.
    static let supportedFileExtensions: [String] = ["txt", "md", "markdown", "vtt", "srt"]

    /// Resolves a format from a file extension, or `nil` for an unsupported one.
    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "txt", "text": self = .plainText
        case "md", "markdown": self = .markdown
        case "vtt": self = .webVTT
        case "srt": self = .subRip
        default: return nil
        }
    }

    /// Resolves a format from a file URL's extension.
    init?(url: URL) {
        self.init(fileExtension: url.pathExtension)
    }

    /// Whether a URL points at a file this importer understands.
    static func isSupportedFile(_ url: URL) -> Bool {
        TranscriptFormat(url: url) != nil
    }
}
