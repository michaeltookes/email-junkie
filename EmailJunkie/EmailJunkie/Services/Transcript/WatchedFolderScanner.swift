import Foundation

/// Pure bookkeeping for the watched-folder transcript source (item 51): decides
/// which files in a folder are newly appeared transcripts that should trigger the
/// follow-up workflow, and which were already processed. The user's files are
/// never moved or deleted — this only tracks paths.
enum WatchedFolderScanner {

    /// Given the folder's current contents and the set of paths already seen,
    /// returns the newly appeared transcript files (in stable order) and the
    /// updated seen-set. Non-transcript files are ignored entirely.
    static func newTranscripts(
        in urls: [URL],
        alreadySeen: Set<String>
    ) -> (new: [URL], seen: Set<String>) {
        var seen = alreadySeen
        var new: [URL] = []
        for url in urls where TranscriptFormat.isSupportedFile(url) {
            if seen.insert(key(for: url)).inserted {
                new.append(url)
            }
        }
        return (new, seen)
    }

    /// The seen-set to seed a freshly started watcher with, so files that already
    /// existed when watching began are not reprocessed as if they just appeared.
    static func seedSeen(from urls: [URL]) -> Set<String> {
        Set(urls.filter { TranscriptFormat.isSupportedFile($0) }.map(key(for:)))
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
