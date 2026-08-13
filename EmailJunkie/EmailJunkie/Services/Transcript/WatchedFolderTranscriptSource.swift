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
/// Event-driven via a `DispatchSourceFileSystemObject` on the root folder plus a
/// bounded recursive rescan loop, mirroring how `InboxWatcher` splits mechanism
/// from policy: the new-vs-seen bookkeeping is the pure `WatchedFolderScanner`,
/// and delivery is `onTranscript`, so a scan can be driven deterministically in
/// tests without real FS events. A file is marked processed only after it is
/// ingested *and* accepted by the delivery callback, so a file that appears
/// mid-write or arrives before the app can draft is retried on a later scan
/// rather than being permanently dropped. It never moves or deletes the user's
/// files.
@MainActor
final class WatchedFolderTranscriptSource: TranscriptSource {

    let kind: TranscriptSourceKind = .watchedFolder
    var onTranscript: ((IngestedTranscript) async -> Bool)?

    /// Reports a watch-start or watch-loss failure so the owner can surface it.
    var onError: ((WatchedFolderError) -> Void)?

    let folderURL: URL
    private let fileManager: FileManager
    private var source: DispatchSourceFileSystemObject?
    private var recursiveRescanTask: Task<Void, Never>?
    private var rejectedDeliveryRetryTask: Task<Void, Never>?
    private var fileStabilityRetryTask: Task<Void, Never>?
    private var pendingFileStability: [String: PendingFileStability] = [:]
    private var seen: [String: WatchedFolderFileSnapshot] = [:]
    private var processing: Set<String> = []
    private var isRunning = false
    var recursiveRescanDelayNanoseconds: UInt64 = 30_000_000_000
    var rejectedDeliveryRetryDelayNanoseconds: UInt64 = 30_000_000_000
    var fileStabilityDelayNanoseconds: UInt64 = 2_000_000_000

    #if DEBUG
    var onAfterSeedSeenForTesting: (() -> Void)?
    #endif

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
        seen = WatchedFolderScanner.seedSeenVersions(from: currentContents())
        #if DEBUG
        onAfterSeedSeenForTesting?()
        #endif
        guard openWatch() else {
            report(.cannotOpenFolder(folderURL.path))
            return
        }
        isRunning = true
        startRecursiveRescanLoop()
        Task { @MainActor [weak self] in
            await self?.scanForNewTranscripts()
        }
    }

    /// Stops watching and releases the folder descriptor. Idempotent.
    func stop() {
        isRunning = false
        cancelScheduledWork()
        teardownWatch()
    }

    /// Rescans the folder and delivers any newly appeared transcript files. A file
    /// is marked processed only once it ingests and the delivery callback accepts
    /// it. Internal so the FS-event handler and tests can trigger a scan.
    func scanForNewTranscripts() async {
        guard isRunning else { return }
        let contents = currentContents()
        seen = WatchedFolderScanner.reconcileSeenVersions(seen, with: contents)
        let candidates = WatchedFolderScanner.newTranscripts(in: contents, alreadySeen: seen)
        let candidateKeys = Set(candidates.map(WatchedFolderScanner.seenKey(for:)))
        pendingFileStability = pendingFileStability.filter { candidateKeys.contains($0.key) }
        for url in candidates {
            guard isRunning else { return }
            let key = WatchedFolderScanner.seenKey(for: url)
            guard !processing.contains(key) else { continue }
            guard isStableForDelivery(url, key: key) else { continue }
            guard let deliveredSnapshot = pendingFileStability[key]?.snapshot else {
                scheduleFileStabilityRetry()
                continue
            }
            guard let ingested = try? TranscriptIngest.fromFile(url, origin: .watchedFolder) else {
                // Transient (e.g. a file still being written reads empty): leave
                // it unseen so a later write event or stability retry can retry.
                scheduleFileStabilityRetry()
                continue
            }
            processing.insert(key)
            let accepted = await onTranscript?(ingested) == true
            processing.remove(key)
            guard isRunning else { return }
            if accepted {
                seen[key] = deliveredSnapshot
                pendingFileStability.removeValue(forKey: key)
            } else {
                scheduleRejectedDeliveryRetry()
            }
        }
    }

    // MARK: - Mechanism

    private func currentContents() -> [URL] {
        currentRecursiveURLs().filter { !isDirectory($0) }
    }

    private func currentRecursiveURLs() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Opens the folder descriptor and starts the dispatch source. Returns whether
    /// the open succeeded. Each source's cancel handler closes its own captured
    /// descriptor, so a re-open can never race a stale cancel into a wrong close.
    private func openWatch() -> Bool {
        guard let watch = makeWatch(for: folderURL, isRoot: true) else { return false }
        source = watch
        return true
    }

    private func makeWatch(for url: URL, isRoot: Bool) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        watch.setEventHandler { [weak self] in
            let flags = watch.data
            Task { @MainActor in
                await self?.handleEvent(flags, isRoot: isRoot)
            }
        }
        watch.setCancelHandler { close(descriptor) }
        watch.resume()
        return watch
    }

    private func teardownWatch() {
        source?.cancel()
        source = nil
    }

    private func cancelScheduledWork() {
        recursiveRescanTask?.cancel()
        rejectedDeliveryRetryTask?.cancel()
        fileStabilityRetryTask?.cancel()
        recursiveRescanTask = nil
        rejectedDeliveryRetryTask = nil
        fileStabilityRetryTask = nil
        pendingFileStability.removeAll()
    }

    private func startRecursiveRescanLoop() {
        guard recursiveRescanTask == nil else { return }
        recursiveRescanTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.recursiveRescanDelayNanoseconds)
                if Task.isCancelled { return }
                await self.scanForNewTranscripts()
            }
        }
    }

    private func isStableForDelivery(_ url: URL, key: String) -> Bool {
        guard let snapshot = WatchedFolderFileSnapshot(url: url) else {
            pendingFileStability.removeValue(forKey: key)
            return false
        }

        let now = Date()
        if let pending = pendingFileStability[key], pending.snapshot == snapshot {
            if now.timeIntervalSince(pending.observedAt) >= fileStabilityDelaySeconds {
                return true
            }
            scheduleFileStabilityRetry()
            return false
        }

        pendingFileStability[key] = PendingFileStability(snapshot: snapshot, observedAt: now)
        scheduleFileStabilityRetry()
        return false
    }

    private var fileStabilityDelaySeconds: TimeInterval {
        TimeInterval(fileStabilityDelayNanoseconds) / 1_000_000_000
    }

    private func scheduleFileStabilityRetry() {
        guard isRunning, fileStabilityRetryTask == nil else { return }
        fileStabilityRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.fileStabilityDelayNanoseconds)
            } catch {
                self.fileStabilityRetryTask = nil
                return
            }
            guard self.isRunning else {
                self.fileStabilityRetryTask = nil
                return
            }
            self.fileStabilityRetryTask = nil
            await self.scanForNewTranscripts()
        }
    }

    private func scheduleRejectedDeliveryRetry() {
        guard isRunning, rejectedDeliveryRetryTask == nil else { return }
        rejectedDeliveryRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.rejectedDeliveryRetryDelayNanoseconds)
            } catch {
                self.rejectedDeliveryRetryTask = nil
                return
            }
            guard self.isRunning else {
                self.rejectedDeliveryRetryTask = nil
                return
            }
            self.rejectedDeliveryRetryTask = nil
            await self.scanForNewTranscripts()
        }
    }

    private func handleEvent(_ flags: DispatchSource.FileSystemEvent, isRoot: Bool) async {
        if isRoot, flags.contains(.delete) || flags.contains(.rename) {
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
            cancelScheduledWork()
            report(.folderUnavailable(folderURL.path))
            return
        }
        guard openWatch() else {
            isRunning = false
            cancelScheduledWork()
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

private struct PendingFileStability {
    var snapshot: WatchedFolderFileSnapshot
    var observedAt: Date
}
