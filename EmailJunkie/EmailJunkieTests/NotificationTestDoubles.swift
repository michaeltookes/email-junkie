import Foundation
@testable import EmailJunkie

/// Records notification calls and lets tests simulate the user acting on a
/// delivered notification via `onAction`.
@MainActor
final class FakeDraftNotifier: DraftNotifying {
    var onAction: ((DraftNotificationAction, String) async -> Void)?
    private(set) var authorizationRequested = false
    private(set) var notifiedDrafts: [Draft] = []
    private(set) var removedIdentities: [String] = []

    nonisolated init() {}

    func requestAuthorization() { authorizationRequested = true }

    func notify(for draft: Draft, sendBehavior: SendBehavior) {
        notifiedDrafts.append(draft)
    }

    func removeNotification(identity: String) {
        removedIdentities.append(identity)
    }

    /// Simulates the user acting on the notification for `identity`.
    func fireAction(_ action: DraftNotificationAction, identity: String) async {
        await onAction?(action, identity)
    }
}
