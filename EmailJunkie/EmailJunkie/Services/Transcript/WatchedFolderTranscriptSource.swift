import Foundation
import os

private let watchedFolderLogger = Logger(subsystem: "com.tookes.EmailJunkie", category: "TranscriptFolder")

/// A watched-folder failure surfaced to the owner so the UI never claims to be
/// watching a folder it can't actually reach (item 51).
enum WatchedFolderError: Error, Equatable {
    /// The folder couldn't be opened for watching (missing, or no permission).
    case cannotOpenFolder(String)
    /// The folder was renamed or deleted while watching and can't be re-opened.
    case folderUnavailable(String)
}

/// Watches a folder for new transcript files and delivers each newly appeared one
/// to `onTranscript` (item 51) — e.g. Zoom's local recording directory. This is
/// the v1 `TranscriptSource`; platform integrations (item 53) and native capture
/// (item 54) will conform the same way.
///
/// Event-driven via a `DispatchSourceFileSystemObject` on the folder descriptor,
/// mirroring how `InboxWatcher` splits mechanism from policy: the new-vs-seen
/// bookkeeping is the pure `WatchedFolderScanner`, and delivery is `onTranscript`,
/// so a scan can be driven deterministically in tests without real FS events. A
/// file is marked processed only after it is ingested *and* accepted by the
/// delivery callback, so a file that appears mid-write or arrives before the app
/// can draft is retried on a later scan rather than being permanently dropped. It
/// never moves or deletes the user's files.
@MainActor
final class WatchedFolderTranscriptSource: TranscriptSource {

    let kind: TranscriptSourceKind = .watchedFolder
    var onTranscript: ((IngestedTranscript) async -> Bool)?

    /// Reports a watch-start or watch-loss failure so the owner can surface it.
    var onError: ((WatchedFolderError) -> Void)?

    let folderURL: URL
    private let fileManager: FileManager
    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private var processing: Set<String> = []
    private var isRunning = false

    /// Whether the folder is currently being watched. Reflects reality — it is
    /// only true after the descriptor opened successfully.
    var isActive: Bool { isRunning }

    init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL
        self.fileManager = fileManager
    }

    /// Begins watching. Files already present when watching starts are seeded as
    /// seen, so only files that appear afterwards trigger the workflow. If the
    /// folder can't be opened, reports the failure and stays inactive. Idempotent.
    func start() {
        guard !isRunning else { return }
        seen = WatchedFolderScanner.seedSeen(from: currentContents())
        guard openWatch() else {
            report(.cannotOpenFolder(folderURL.path))
            return
        }
        isRunning = true
    }

    /// Stops watching and releases the folder descriptor. Idempotent.
    func stop() {
        isRunning = false
        teardownWatch()
    }

    /// Rescans the folder and delivers any newly appeared transcript files. A file
    /// is marked processed only once it ingests and the delivery callback accepts
    /// it. Internal so the FS-event handler and tests can trigger a scan.
    func scanForNewTranscripts() async {
        for url in WatchedFolderScanner.newTranscripts(in: currentContents(), alreadySeen: seen) {
            let key = WatchedFolderScanner.seenKey(for: url)
            guard !processing.contains(key) else { continue }
            guard let ingested = try? TranscriptIngest.fromFile(url, origin: .watchedFolder) else {
                // Transient (e.g. a file still being written reads empty): leave it
                // unseen so a later write event or scan retries it.
                continue
            }
            processing.insert(key)
            let accepted = await onTranscript?(ingested) == true
            processing.remove(key)
            if accepted {
                seen.insert(key)
            }
        }
    }

    // MARK: - Mechanism

    private func currentContents() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Opens the folder descriptor and starts the dispatch source. Returns whether
    /// the open succeeded. Each source's cancel handler closes its own captured
    /// descriptor, so a re-open can never race a stale cancel into a wrong close.
    private func openWatch() -> Bool {
        let descriptor = open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        watch.setEventHandler { [weak self] in
            let flags = watch.data
            Task { @MainActor in
                await self?.handleEvent(flags)
            }
        }
        watch.setCancelHandler { close(descriptor) }
        source = watch
        watch.resume()
        return true
    }

    private func teardownWatch() {
        source?.cancel()
        source = nil
    }

    private func handleEvent(_ flags: DispatchSource.FileSystemEvent) async {
        if flags.contains(.delete) || flags.contains(.rename) {
            await handleFolderMoved()
        } else {
            await scanForNewTranscripts()
        }
    }

    /// The watched folder itself was renamed or deleted, so the descriptor points
    /// at a stale inode. Re-open the path if something is still there; otherwise
    /// surface the loss so the UI stops claiming to watch.
    private func handleFolderMoved() async {
        teardownWatch()
        guard fileManager.fileExists(atPath: folderURL.path) else {
            isRunning = false
            report(.folderUnavailable(folderURL.path))
            return
        }
        guard openWatch() else {
            isRunning = false
            report(.cannotOpenFolder(folderURL.path))
            return
        }
        await scanForNewTranscripts()
    }

    private func report(_ error: WatchedFolderError) {
        watchedFolderLogger.error("Transcript folder watch failed: \(String(describing: error))")
        onError?(error)
    }
}
