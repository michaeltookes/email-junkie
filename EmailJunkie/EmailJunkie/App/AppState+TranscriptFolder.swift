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
    /// Called at launch and after settings changes. Idempotent.
    func startTranscriptFolderWatchingIfEnabled() {
        guard transcriptWatchedFolderEnabled, let url = transcriptWatchedFolderURL else {
            stopTranscriptFolderWatching()
            return
        }
        // Rebuild if the target folder changed; otherwise leave the running one.
        if let existing = transcriptFolderSource, existing.folderURL == url { return }
        stopTranscriptFolderWatching()

        transcriptFolderError = nil
        let source = WatchedFolderTranscriptSource(folderURL: url)
        source.onTranscript = { [weak self] ingested in
            self?.handleWatchedTranscript(ingested)
        }
        transcriptFolderSource = source
        source.start()
        transcriptFolderLogger.info("Started watching transcript folder")
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
    /// adds recipients in review before approving.
    func handleWatchedTranscript(_ ingested: IngestedTranscript) {
        guard canCreateFollowUp else {
            transcriptFolderError =
                "A transcript arrived, but connect an email account and AI provider to draft follow-ups."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.createFollowUp(from: ingested)
            } catch {
                self.transcriptFolderError = Self.draftMessage(for: error)
                transcriptFolderLogger.error("Watched-folder follow-up failed: \(error.localizedDescription)")
            }
        }
    }
}
