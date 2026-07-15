import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "Notifications")

/// `userInfo` key carrying a draft's `identity` on its notification.
private let draftIdentityUserInfoKey = "draftIdentity"

/// An action the user took on a draft-ready notification.
enum DraftNotificationAction: Equatable {
    /// Approve inline (send or save per the send-behavior setting).
    case approve
    /// Deny inline (discard the draft).
    case deny
    /// Open the review window (the notification body was clicked).
    case open
}

/// Posts native notifications when a draft is ready and routes the user's action
/// back to the app. Injectable so `AppState` can be tested without the real
/// `UNUserNotificationCenter`.
@MainActor
protocol DraftNotifying: AnyObject {
    /// Called on the main actor when the user acts on a notification; the second
    /// argument is the draft's `identity`.
    var onAction: ((DraftNotificationAction, String) -> Void)? { get set }

    /// Requests notification authorization (no-op if already decided).
    func requestAuthorization()

    /// Posts a notification announcing `draft`; `sendBehavior` tailors the copy.
    func notify(for draft: Draft, sendBehavior: SendBehavior)

    /// Removes any delivered/pending notification for the given draft identity.
    func removeNotification(identity: String)
}

/// A no-op notifier used as the default (and in tests) so constructing an
/// `AppState` never touches `UNUserNotificationCenter`. The real app injects
/// `UserNotificationService` via the app delegate.
@MainActor
final class NullDraftNotifier: DraftNotifying {
    var onAction: ((DraftNotificationAction, String) -> Void)?
    nonisolated init() {}
    func requestAuthorization() {}
    func notify(for draft: Draft, sendBehavior: SendBehavior) {}
    func removeNotification(identity: String) {}
}

/// `DraftNotifying` backed by `UNUserNotificationCenter`.
///
/// Registers a "draft ready" category with inline **Approve** and **Deny**
/// actions; tapping the body triggers `.open`. The center is only touched from
/// `requestAuthorization()` onward, so unit tests that never call it stay off
/// the notification system entirely.
@MainActor
final class UserNotificationService: NSObject, DraftNotifying {

    var onAction: ((DraftNotificationAction, String) -> Void)?

    private let center = UNUserNotificationCenter.current()

    static let categoryIdentifier = "DRAFT_READY"
    static let approveActionIdentifier = "APPROVE_DRAFT"
    static let denyActionIdentifier = "DENY_DRAFT"

    func requestAuthorization() {
        center.delegate = self
        registerCategory()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription)")
            } else {
                logger.info("Notification authorization granted: \(granted)")
            }
        }
    }

    func notify(for draft: Draft, sendBehavior: SendBehavior) {
        let content = UNMutableNotificationContent()
        let sender = draft.sourceFrom?.name ?? draft.sourceFrom?.email ?? "someone"
        content.title = "Reply ready for \(sender)"
        content.subtitle = draft.sourceSubject
        content.body = Self.snippet(draft.body)
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [draftIdentityUserInfoKey: draft.identity]
        content.threadIdentifier = draft.sourceAccountEmail ?? "EmailJunkie"

        let request = UNNotificationRequest(
            identifier: draft.identity,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                logger.error("Failed to post draft notification: \(error.localizedDescription)")
            }
        }
    }

    func removeNotification(identity: String) {
        center.removeDeliveredNotifications(withIdentifiers: [identity])
        center.removePendingNotificationRequests(withIdentifiers: [identity])
    }

    // MARK: - Helpers

    static func draftActions() -> [UNNotificationAction] {
        let approve = UNNotificationAction(
            identifier: Self.approveActionIdentifier,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: Self.denyActionIdentifier,
            title: "Deny",
            options: [.authenticationRequired, .destructive]
        )
        return [approve, deny]
    }

    private func registerCategory() {
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: Self.draftActions(),
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// A single-line preview of the reply body for the notification.
    static func snippet(_ body: String, maxChars: Int = 140) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > maxChars ? String(collapsed.prefix(maxChars)) + "…" : collapsed
    }

    private func action(for actionIdentifier: String) -> DraftNotificationAction {
        switch actionIdentifier {
        case Self.approveActionIdentifier:
            return .approve
        case Self.denyActionIdentifier:
            return .deny
        default:
            // UNNotificationDefaultActionIdentifier (body tap) and dismiss.
            return .open
        }
    }
}

extension UserNotificationService: UNUserNotificationCenterDelegate {

    /// Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identity = response.notification.request.content.userInfo[draftIdentityUserInfoKey] as? String
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard actionIdentifier != UNNotificationDismissActionIdentifier,
                  let identity else { return }
            onAction?(action(for: actionIdentifier), identity)
        }
    }
}
