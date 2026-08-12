import Foundation

/// Pure bookkeeping for the watched-folder transcript source (item 51): decides
/// which files in a folder are candidate transcripts not yet processed. The user's
/// files are never moved or deleted — this only compares paths.
///
/// Committing a file to the "seen" set is deliberately the caller's job, done only
/// after the file is successfully ingested and accepted, so a file that appears
/// mid-write (and momentarily reads empty) or arrives while the app can't yet draft
/// is retried on a later scan rather than being permanently dropped.
enum WatchedFolderScanner {

    /// The candidate transcript files in `urls` that haven't been seen yet, in
    /// stable order. Non-transcript files are ignored entirely.
    static func newTranscripts(in urls: [URL], alreadySeen: Set<String>) -> [URL] {
        urls.filter { TranscriptFormat.isSupportedFile($0) && !alreadySeen.contains(seenKey(for: $0)) }
    }

    /// The seen-set to seed a freshly started watcher with, so files that already
    /// existed when watching began are not reprocessed as if they just appeared.
    static func seedSeen(from urls: [URL]) -> Set<String> {
        Set(urls.filter { TranscriptFormat.isSupportedFile($0) }.map(seenKey(for:)))
    }

    /// The stable key used to track a file as processed.
    static func seenKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
