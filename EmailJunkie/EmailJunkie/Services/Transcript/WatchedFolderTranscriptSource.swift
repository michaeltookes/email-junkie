import Foundation

/// Watches a folder for new transcript files and delivers each newly appeared one
/// to `onTranscript` (item 51) — e.g. Zoom's local recording directory. This is
/// the v1 `TranscriptSource`; platform integrations (item 53) and native capture
/// (item 54) will conform the same way.
///
/// Event-driven via a `DispatchSourceFileSystemObject` on the folder descriptor,
/// mirroring how `InboxWatcher` splits mechanism from policy: the new-vs-seen
/// bookkeeping is the pure `WatchedFolderScanner`, and delivery is `onTranscript`,
/// so a scan can be driven deterministically in tests without real FS events. It
/// never moves or deletes the user's files.
@MainActor
final class WatchedFolderTranscriptSource: TranscriptSource {

    let kind: TranscriptSourceKind = .watchedFolder
    var onTranscript: ((IngestedTranscript) -> Void)?

    let folderURL: URL
    private let fileManager: FileManager
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var seen: Set<String> = []
    private var isRunning = false

    init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL
        self.fileManager = fileManager
    }

    /// Begins watching. Files already present when watching starts are seeded as
    /// seen, so only files that appear afterwards trigger the workflow. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        seen = WatchedFolderScanner.seedSeen(from: currentContents())
        openWatch()
    }

    /// Stops watching and releases the folder descriptor. Idempotent.
    func stop() {
        isRunning = false
        source?.cancel()
        source = nil
    }

    /// Rescans the folder and delivers any newly appeared transcript files.
    /// Internal so the FS-event handler and tests can trigger a scan.
    func scanForNewTranscripts() {
        let result = WatchedFolderScanner.newTranscripts(in: currentContents(), alreadySeen: seen)
        seen = result.seen
        for url in result.new {
            guard let ingested = try? TranscriptIngest.fromFile(url, origin: .watchedFolder) else { continue }
            onTranscript?(ingested)
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

    private func openWatch() {
        descriptor = open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scanForNewTranscripts() }
        }
        watch.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source = watch
        watch.resume()
    }
}
