import Foundation

/// Where an ingested transcript came from (item 51). New origins plug in the way
/// LLM providers do — add a case here plus a producer — so the follow-up
/// pipeline never changes as acquisition grows: platform APIs (item 53) and
/// native on-device capture (item 54) will add their own cases.
enum TranscriptSourceKind: Equatable {
    /// Text the user pasted into the composer.
    case paste
    /// A file the user chose or dragged in.
    case file
    /// A file that appeared in the user's watched folder.
    case watchedFolder
}

/// A transcript handed to the follow-up drafting pipeline, tagged with its origin
/// and format so the parser and prompt can adapt.
struct IngestedTranscript: Equatable {
    /// The raw file/paste contents, before parsing.
    var rawText: String
    /// The detected format, driving how `TranscriptParser` normalizes it.
    var format: TranscriptFormat
    /// Where the transcript came from.
    var origin: TranscriptSourceKind
    /// A suggested follow-up title (e.g. the file's name), or `nil` for a paste.
    var suggestedTitle: String?

    /// The parsed, speaker-preserving plain text for this transcript.
    func parsed() -> ParsedTranscript {
        TranscriptParser.parse(rawText, format: format)
    }
}

/// A continuous producer of transcripts. The watched folder is the v1 conformer;
/// platform integrations (item 53) and native capture (item 54) will conform the
/// same way, delivering each newly available transcript to `onTranscript` for
/// its lifetime until `stop()`. One-shot manual ingestion (paste/file) builds an
/// `IngestedTranscript` directly via `TranscriptIngest` rather than conforming.
@MainActor
protocol TranscriptSource: AnyObject {
    /// The origin category this source represents.
    var kind: TranscriptSourceKind { get }
    /// Invoked with each newly available transcript while the source is running.
    /// Returns `true` when the transcript was accepted for processing; a source
    /// that tracks which inputs it has handled (e.g. the watched folder) should
    /// only mark the input processed on `true`, so a rejected input is retried
    /// rather than dropped.
    var onTranscript: ((IngestedTranscript) -> Bool)? { get set }
    /// Begins producing transcripts.
    func start()
    /// Stops producing transcripts and releases any OS resources.
    func stop()
}

/// Errors from manual (paste/file) transcript ingestion.
enum TranscriptIngestError: Error, Equatable {
    /// The file's extension isn't a transcript format we parse.
    case unsupportedFormat(String)
    /// The paste or file had no usable text.
    case emptyTranscript
    /// The file could not be read/decoded.
    case unreadableFile(String)
}

/// Builds `IngestedTranscript` values from the one-shot manual sources (paste and
/// file). Kept separate from the continuous `TranscriptSource` protocol because a
/// user action produces exactly one transcript with no lifecycle to manage.
enum TranscriptIngest {

    /// Wraps pasted text as an ingested transcript. Callers pass the format the
    /// user selected (defaulting to plain text).
    static func fromPaste(_ text: String, format: TranscriptFormat = .plainText) throws -> IngestedTranscript {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptIngestError.emptyTranscript
        }
        return IngestedTranscript(rawText: text, format: format, origin: .paste, suggestedTitle: nil)
    }

    /// Reads a transcript file into an ingested transcript, inferring the format
    /// from its extension. Falls back to lenient decoding for non-UTF-8 exports.
    static func fromFile(_ url: URL, origin: TranscriptSourceKind = .file) throws -> IngestedTranscript {
        guard let format = TranscriptFormat(url: url) else {
            throw TranscriptIngestError.unsupportedFormat(url.pathExtension)
        }
        let raw = try readText(url)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptIngestError.emptyTranscript
        }
        return IngestedTranscript(
            rawText: raw,
            format: format,
            origin: origin,
            suggestedTitle: url.deletingPathExtension().lastPathComponent
        )
    }

    private static func readText(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw TranscriptIngestError.unreadableFile(url.lastPathComponent)
        }
        return decoded
    }
}
