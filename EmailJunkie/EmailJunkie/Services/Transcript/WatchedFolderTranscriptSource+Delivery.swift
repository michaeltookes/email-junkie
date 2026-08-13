import Foundation

@MainActor
extension WatchedFolderTranscriptSource {

    func ingestTranscript(at url: URL) async throws -> IngestedTranscript {
        try await TranscriptIngest.fromFileDetached(url, origin: .watchedFolder)
    }

    func transcriptDeliveryResult(
        for ingested: IngestedTranscript,
        shouldCommit: @escaping WatchedTranscriptShouldCommit
    ) async -> WatchedTranscriptDeliveryResult {
        if let onTranscriptValidatedDelivery {
            return await onTranscriptValidatedDelivery(ingested, shouldCommit)
        }
        if let onTranscriptDelivery {
            return await onTranscriptDelivery(ingested)
        }
        return await onTranscript?(ingested) == true ? .accepted : .deferred
    }

    func isCurrentDeliverySnapshot(_ url: URL, snapshot: WatchedFolderFileSnapshot) -> Bool {
        isRunning && WatchedFolderFileSnapshot(url: url) == snapshot
    }
}
