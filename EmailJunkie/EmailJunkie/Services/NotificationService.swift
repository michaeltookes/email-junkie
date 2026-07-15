import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "Notifications")

/// `userInfo` key carrying a draft's `identity` on its notification.
private let draftIdentityUserInfoKey = "draftIdentity"
/// `userInfo` key carrying the send behavior displayed on the notification.
private let draftSendBehaviorUserInfoKey = "sendBehavior"

/// An action the user took on a draft-ready notification.
enum DraftNotificationAction: Equatable {
    /// Approve inline using the send behavior displayed on the notification.
    case approve(SendBehavior)
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
    /// argument is the draft's `identity`. The notification response is not
    /// completed until this async handler returns.
    var onAction: ((DraftNotificationAction, String) async -> Void)? { get set }

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
    var onAction: ((DraftNotificationAction, String) async -> Void)?
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

    var onAction: ((DraftNotificationAction, String) async -> Void)?

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
        content.body = Self.notificationBody(replyBody: draft.body, sendBehavior: sendBehavior)
        content.categoryIdentifier = Self.categoryIdentifier(for: sendBehavior)
        content.userInfo = Self.notificationUserInfo(for: draft, sendBehavior: sendBehavior)
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

    static func categoryIdentifier(for sendBehavior: SendBehavior) -> String {
        switch sendBehavior {
        case .autoSend:
            return "\(categoryIdentifier)_AUTO_SEND"
        case .saveAsDraft:
            return "\(categoryIdentifier)_SAVE_DRAFT"
        }
    }

    static func approveActionTitle(for sendBehavior: SendBehavior) -> String {
        switch sendBehavior {
        case .autoSend:
            return "Send Now"
        case .saveAsDraft:
            return "Save Draft"
        }
    }

    static func approvalNotice(for sendBehavior: SendBehavior) -> String {
        switch sendBehavior {
        case .autoSend:
            return "Approve sends this reply now"
        case .saveAsDraft:
            return "Approve saves this as a draft"
        }
    }

    static func draftActions(for sendBehavior: SendBehavior = .default) -> [UNNotificationAction] {
        let approve = UNNotificationAction(
            identifier: Self.approveActionIdentifier,
            title: Self.approveActionTitle(for: sendBehavior),
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
        let categories = Set(SendBehavior.allCases.map { sendBehavior in
            UNNotificationCategory(
                identifier: Self.categoryIdentifier(for: sendBehavior),
                actions: Self.draftActions(for: sendBehavior),
                intentIdentifiers: [],
                options: []
            )
        })
        center.setNotificationCategories(categories)
    }

    /// A single-line preview of the reply body for the notification.
    static func snippet(_ body: String, maxChars: Int = 140) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > maxChars ? String(collapsed.prefix(maxChars)) + "…" : collapsed
    }

    static func notificationBody(replyBody: String, sendBehavior: SendBehavior) -> String {
        "\(approvalNotice(for: sendBehavior)). \(snippet(replyBody))"
    }

    static func notificationUserInfo(for draft: Draft, sendBehavior: SendBehavior) -> [AnyHashable: Any] {
        [
            draftIdentityUserInfoKey: draft.identity,
            draftSendBehaviorUserInfoKey: sendBehavior.rawValue
        ]
    }

    static func action(for actionIdentifier: String, userInfo: [AnyHashable: Any]) -> DraftNotificationAction {
        switch actionIdentifier {
        case Self.approveActionIdentifier:
            guard let rawSendBehavior = userInfo[draftSendBehaviorUserInfoKey] as? String,
                  let sendBehavior = SendBehavior(rawValue: rawSendBehavior) else {
                return .open
            }
            return .approve(sendBehavior)
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
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard actionIdentifier != UNNotificationDismissActionIdentifier,
                  let identity else { return }
            await onAction?(Self.action(for: actionIdentifier, userInfo: userInfo), identity)
        }
    }
}
