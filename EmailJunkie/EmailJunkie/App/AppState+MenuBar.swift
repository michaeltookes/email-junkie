import Foundation

/// Menu-bar-facing derived state. Kept in a separate file so `AppState` stays
/// within the file/type length limits.
extension AppState {

    /// Human-readable status for the menu bar.
    var statusText: String {
        guard isAccountConnected else { return "No account connected" }
        switch watchStatus {
        case .idle:
            return "Idle"
        case .watching:
            return pendingDraftCount > 0
                ? "\(pendingDraftCount) draft\(pendingDraftCount == 1 ? "" : "s") pending"
                : "Watching inbox"
        case .paused:
            return "Paused"
        }
    }
}
