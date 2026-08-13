import Foundation

/// Outcome from the app after the watched-folder source delivers an ingested
/// transcript.
enum WatchedTranscriptDeliveryResult: Equatable {
    /// The transcript is durably handled and may be marked seen.
    case accepted
    /// Retry with a bounded backoff budget for transient post-generation failures.
    case retry
    /// Leave pending until app configuration or credentials change.
    case deferred
}

typealias WatchedTranscriptShouldCommit = () -> Bool
typealias WatchedTranscriptValidatedDelivery = (
    IngestedTranscript,
    @escaping WatchedTranscriptShouldCommit
) async -> WatchedTranscriptDeliveryResult

struct WatchedFolderRejectedDeliveryState: Equatable {
    var snapshot: WatchedFolderFileSnapshot
    var attempts: Int
    var nextRetryAt: Date
    var isDeferred = false
}

enum WatchedFolderRejectedDeliveryAction: Equatable {
    case scheduled
    case exhausted
}
