import Foundation
import os

private let transcriptFolderLogger = Logger(subsystem: "com.tookes.EmailJunkie", category: "TranscriptFolder")

/// Watched-folder lifecycle for the post-call follow-up workflow (item 51). Kept
/// in its own file so `AppState` stays within length limits.
extension AppState {

    /// The configured watched folder as a URL, or `nil` when unset.
    var transcriptWatchedFolderURL: URL? {
        let trimmed = transcriptWatchedFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Starts the watcher if the feature is enabled and a folder is configured.
    /// Called at launch and after settings/connection changes. When a watcher for
    /// the same folder is already running it triggers a catch-up scan, so a
    /// transcript that arrived while the app couldn't yet draft is picked up once
    /// the app becomes ready. Idempotent.
    func startTranscriptFolderWatchingIfEnabled() {
        guard transcriptWatchedFolderEnabled, let url = transcriptWatchedFolderURL else {
            stopTranscriptFolderWatching()
            return
        }
        // Rebuild if the target folder changed or a prior source failed to start;
        // otherwise catch up the running one.
        if let existing = transcriptFolderSource, existing.folderURL == url {
            guard existing.isActive else {
                stopTranscriptFolderWatching()
                return startTranscriptFolderWatchingIfEnabled()
            }
            Task { @MainActor in
                await existing.scanForNewTranscripts()
            }
            return
        }
        stopTranscriptFolderWatching()

        transcriptFolderError = nil
        let source = WatchedFolderTranscriptSource(folderURL: url)
        source.onTranscript = { [weak self] ingested in
            await self?.handleWatchedTranscript(ingested) ?? false
        }
        source.onError = { [weak self] error in
            self?.transcriptFolderError = Self.watchedFolderMessage(for: error)
        }
        transcriptFolderSource = source
        source.start()
        transcriptFolderLogger.info("Started watching transcript folder")
    }

    /// User-facing copy for a watched-folder failure.
    static func watchedFolderMessage(for error: WatchedFolderError) -> String {
        switch error {
        case .cannotOpenFolder(let path):
            return "Couldn't watch \(path). Check the folder exists and Email Junkie has access to it."
        case .folderUnavailable(let path):
            return "The watched folder \(path) is no longer available. Choose it again in Settings."
        }
    }

    /// Stops and tears down the watcher. Idempotent.
    func stopTranscriptFolderWatching() {
        transcriptFolderSource?.stop()
        transcriptFolderSource = nil
    }

    /// Enables/disables the watched folder from the UI, persisting and (re)starting
    /// or stopping the watcher to match.
    func setTranscriptWatchedFolderEnabled(_ enabled: Bool) {
        guard enabled != transcriptWatchedFolderEnabled else { return }
        transcriptWatchedFolderEnabled = enabled
        saveSettings()
        startTranscriptFolderWatchingIfEnabled()
    }

    /// Points the watched folder at a new path from the UI, persisting and
    /// restarting the watcher to match.
    func setTranscriptWatchedFolderPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != transcriptWatchedFolderPath else { return }
        transcriptWatchedFolderPath = trimmed
        saveSettings()
        startTranscriptFolderWatchingIfEnabled()
    }

    /// Handles a transcript that appeared in the watched folder: drafts a follow-up
    /// and enqueues it with no recipients yet (auto-fill is item 52), so the user
    /// adds recipients in review before approving. Returns whether the transcript
    /// was durably accepted for processing — `false` when the app can't yet draft
    /// or enqueue the pending draft, so the source leaves the file unseen and
    /// retries it once the app is ready rather than dropping it.
    @discardableResult
    func handleWatchedTranscript(_ ingested: IngestedTranscript) async -> Bool {
        guard canCreateFollowUp else {
            transcriptFolderError =
                "A transcript arrived, but connect an email account and AI provider to draft follow-ups."
            return false
        }
        do {
            _ = try await createFollowUp(from: ingested)
            return true
        } catch {
            transcriptFolderError = Self.draftMessage(for: error)
            transcriptFolderLogger.error("Watched-folder follow-up failed: \(error.localizedDescription)")
            return false
        }
    }
}
