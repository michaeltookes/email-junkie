import Foundation

struct WatchedFolderFileSnapshot: Codable, Equatable, Sendable {
    var fileSize: Int
    var modificationDate: Date?
    var creationDate: Date?
    var fileIdentity: String?

    init(fileSize: Int, modificationDate: Date?, creationDate: Date?, fileIdentity: String?) {
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.fileIdentity = fileIdentity
    }

    init?(url: URL) {
        guard let values = try? url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
                .fileResourceIdentifierKey
            ]
        ), let fileSize = values.fileSize else {
            return nil
        }
        self.fileSize = fileSize
        modificationDate = values.contentModificationDate
        creationDate = values.creationDate
        if let data = values.fileResourceIdentifier as? Data {
            fileIdentity = data.base64EncodedString()
        } else if let identifier = values.fileResourceIdentifier {
            fileIdentity = String(describing: identifier)
        } else {
            fileIdentity = nil
        }
    }

}

/// Pure bookkeeping for the watched-folder transcript source (item 51): decides
/// which files in a folder are candidate transcripts not yet processed. The user's
/// files are never moved or deleted — this only compares path, version, and file
/// identity metadata.
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

    /// Version-aware candidate detection for a running watcher. A path that was
    /// already delivered can become new again if a recorder replaces or rewrites
    /// the file at that path.
    static func newTranscripts(in urls: [URL], alreadySeen: [String: WatchedFolderFileSnapshot]) -> [URL] {
        urls.filter { url in
            guard TranscriptFormat.isSupportedFile(url) else { return false }
            let key = seenKey(for: url)
            return alreadySeen[key] != WatchedFolderFileSnapshot(url: url)
        }
    }

    /// Drops seen entries for files that disappeared, but carries the delivered
    /// version forward when the same file identity is found at a new path.
    static func reconcileSeenVersions(
        _ alreadySeen: [String: WatchedFolderFileSnapshot],
        with urls: [URL]
    ) -> [String: WatchedFolderFileSnapshot] {
        let currentSnapshots = urls.compactMap { url -> (String, WatchedFolderFileSnapshot)? in
            guard TranscriptFormat.isSupportedFile(url),
                  let snapshot = WatchedFolderFileSnapshot(url: url) else { return nil }
            return (seenKey(for: url), snapshot)
        }
        let seenByIdentity = alreadySeen.values.reduce(into: [String: WatchedFolderFileSnapshot]()) { result, snapshot in
            guard let identity = snapshot.fileIdentity else { return }
            result[identity] = snapshot
        }
        return currentSnapshots.reduce(into: [:]) { result, current in
            if let existing = alreadySeen[current.0] {
                result[current.0] = existing
            } else if let identity = current.1.fileIdentity,
                      let moved = seenByIdentity[identity] {
                result[current.0] = moved
            }
        }
    }

    /// The seen-set to seed a freshly started watcher with, so files that already
    /// existed when watching began are not reprocessed as if they just appeared.
    static func seedSeen(from urls: [URL]) -> Set<String> {
        Set(urls.filter { TranscriptFormat.isSupportedFile($0) }.map(seenKey(for:)))
    }

    /// Version-aware seen-set for the live watcher.
    static func seedSeenVersions(from urls: [URL]) -> [String: WatchedFolderFileSnapshot] {
        urls.reduce(into: [:]) { seen, url in
            guard TranscriptFormat.isSupportedFile(url),
                  let snapshot = WatchedFolderFileSnapshot(url: url) else { return }
            seen[seenKey(for: url)] = snapshot
        }
    }

    /// The stable key used to track a file as processed.
    static func seenKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
