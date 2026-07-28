import XCTest
@testable import EmailJunkie

/// Tests for notification action sets (item 13). A flagged "needs input" draft
/// must not offer an Approve action, or a notification tap could auto-send a
/// reply that was never written.
@MainActor
final class NotificationServiceTests: XCTestCase {

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
}
