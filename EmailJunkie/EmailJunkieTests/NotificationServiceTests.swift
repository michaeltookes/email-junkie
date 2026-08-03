import XCTest
import UserNotifications
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

    func testRefreshNotificationDoesNotCreateNotificationWithoutExistingCenterEntry() async {
        let center = FakeUserNotificationCenter()
        let service = UserNotificationService(center: center)

        service.refreshNotification(for: pendingDraft(), sendBehavior: .autoSend)
        await Task.yield()

        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertEqual(center.pendingLookupCount, 1)
        XCTAssertEqual(center.deliveredLookupCount, 1)
    }

    func testRefreshNotificationUpdatesPendingNotificationQuietly() async throws {
        let draft = pendingDraft()
        let center = FakeUserNotificationCenter()
        center.pendingIdentifiers = [draft.identity]
        let service = UserNotificationService(center: center)

        service.refreshNotification(for: draft, sendBehavior: .autoSend)
        await Task.yield()

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(request.identifier, draft.identity)
        XCTAssertTrue(UserNotificationService.suppressesPresentation(userInfo: request.content.userInfo))
        XCTAssertEqual(request.content.interruptionLevel, .passive)
        XCTAssertEqual(center.deliveredLookupCount, 0)
    }

    func testRefreshNotificationUpdatesDeliveredNotificationQuietly() async throws {
        let draft = pendingDraft()
        let center = FakeUserNotificationCenter()
        center.deliveredIdentifiers = [draft.identity]
        let service = UserNotificationService(center: center)

        service.refreshNotification(for: draft, sendBehavior: .saveAsDraft)
        await Task.yield()

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(request.identifier, draft.identity)
        XCTAssertTrue(UserNotificationService.suppressesPresentation(userInfo: request.content.userInfo))
        XCTAssertEqual(request.content.interruptionLevel, .passive)
    }
}

private final class FakeUserNotificationCenter: UserNotificationCentering {
    var delegate: UNUserNotificationCenterDelegate?
    var pendingIdentifiers: Set<String> = []
    var deliveredIdentifiers: Set<String> = []
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var pendingLookupCount = 0
    private(set) var deliveredLookupCount = 0
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var removedDeliveredIdentifiers: [String] = []
    private(set) var removedPendingIdentifiers: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) {
        completionHandler(true, nil)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(nil)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(contentsOf: identifiers)
    }

    func pendingNotificationRequestIdentifiers(completionHandler: @escaping (Set<String>) -> Void) {
        pendingLookupCount += 1
        completionHandler(pendingIdentifiers)
    }

    func deliveredNotificationIdentifiers(completionHandler: @escaping (Set<String>) -> Void) {
        deliveredLookupCount += 1
        completionHandler(deliveredIdentifiers)
    }
}
