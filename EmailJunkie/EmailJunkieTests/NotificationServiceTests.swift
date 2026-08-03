import XCTest
@testable import EmailJunkie

/// Tests for notification action sets (item 13). A flagged "needs input" draft
/// must not offer an Approve action, or a notification tap could auto-send a
/// reply that was never written.
@MainActor
final class NotificationServiceTests: XCTestCase {

    private func pendingDraft() -> Draft {
        Draft(
            id: 7,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch?",
            sourceFrom: nil,
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: Lunch?",
            body: "Thursday works!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testFlaggedNotificationOffersNoApproveAction() {
        let actions = UserNotificationService.needsInputActions()
        XCTAssertFalse(
            actions.contains { $0.identifier == UserNotificationService.approveActionIdentifier },
            "a needs-input notification must never offer Approve"
        )
        XCTAssertTrue(actions.contains { $0.identifier == UserNotificationService.denyActionIdentifier })
    }

    func testReadyDraftNotificationStillOffersApprove() {
        let actions = UserNotificationService.draftActions(for: .autoSend)
        XCTAssertTrue(actions.contains { $0.identifier == UserNotificationService.approveActionIdentifier })
    }

    func testRefreshUserInfoSuppressesPresentation() {
        let normal = UserNotificationService.notificationUserInfo(
            for: pendingDraft(),
            sendBehavior: .autoSend
        )
        XCTAssertFalse(UserNotificationService.suppressesPresentation(userInfo: normal))

        let refresh = UserNotificationService.notificationUserInfo(
            for: pendingDraft(),
            sendBehavior: .autoSend,
            suppressPresentation: true
        )
        XCTAssertTrue(UserNotificationService.suppressesPresentation(userInfo: refresh))
    }

    func testRefreshNotificationContentUsesPassiveDelivery() {
        let normal = UserNotificationService.notificationContent(
            for: pendingDraft(),
            sendBehavior: .autoSend
        )
        XCTAssertNotEqual(normal.interruptionLevel, .passive)

        let refresh = UserNotificationService.notificationContent(
            for: pendingDraft(),
            sendBehavior: .autoSend,
            suppressPresentation: true
        )
        XCTAssertEqual(refresh.interruptionLevel, .passive)
    }
}
