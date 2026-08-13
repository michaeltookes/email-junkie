import Foundation

@MainActor
extension WatchedFolderTranscriptSource {

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
}
