import EmailJunkieMail
import UserNotifications
import XCTest
@testable import EmailJunkie

@MainActor
private final class NotificationActionProbe {
    var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

@MainActor
final class AppStateApprovalTests: XCTestCase {

    private func pendingDraft(id: UInt32 = 1, sourceAccountEmail: String? = "me@gmail.com") -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: sourceAccountEmail,
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: Lunch?",
            body: "Thursday works!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAppState(
        sendBehavior: SendBehavior = .autoSend,
        sendResult: Result<Void, MailError> = .success(()),
        appendResult: Result<Void, MailError> = .success(()),
        seed drafts: [Draft] = []
    ) -> (AppState, FakeAppMailProvider, FakeDraftNotifier, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: sendBehavior.rawValue
        ), pendingDrafts: drafts)
        let provider = FakeAppMailProvider(result: .success(()), appendResult: appendResult, sendResult: sendResult)
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: notifier
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, provider, notifier, persistence)
    }

    private func makeAppStateWithSuspendedSend(
        seed drafts: [Draft]
    ) -> (AppState, SuspendedSendMailProvider, FakeDraftNotifier, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue
        ), pendingDrafts: drafts)
        let provider = SuspendedSendMailProvider()
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: notifier
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, provider, notifier, persistence)
    }

    func testApproveActionLabelReflectsSendBehavior() {
        let (autoSend, _, _, _) = makeAppState(sendBehavior: .autoSend)
        XCTAssertEqual(autoSend.approveActionLabel, "Send")
        let (saveAsDraft, _, _, _) = makeAppState(sendBehavior: .saveAsDraft)
        XCTAssertEqual(saveAsDraft.approveActionLabel, "Save to Drafts")
    }

    func testApproveAutoSendSendsRemovesAndClearsNotification() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, persistence) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sentEnvelope?.recipients, ["alice@example.com"])
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.pendingDraftCount, 0)
        XCTAssertEqual(notifier.removedIdentities, [draft.identity])
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
        XCTAssertNil(appState.approvalError)
        XCTAssertFalse(appState.approvingDraftIDs.contains(draft.identity))
    }

    func testApproveSaveAsDraftAppendsInsteadOfSending() async {
        let draft = pendingDraft()
        let (appState, provider, _, _) = makeAppState(sendBehavior: .saveAsDraft, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.appendedMailbox, .drafts)
        XCTAssertNil(provider.sentRFC822)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testApproveFailureKeepsDraftAndNotification() async {
        let draft = pendingDraft()
        let (appState, _, notifier, persistence) = makeAppState(
            sendBehavior: .autoSend,
            sendResult: .failure(.authenticationFailed("bad app password")),
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.identity), [draft.identity])
        XCTAssertNotNil(appState.approvalError)
        XCTAssertTrue(notifier.removedIdentities.isEmpty)
        XCTAssertFalse(appState.approvingDraftIDs.contains(draft.identity))
    }

    func testApproveDoesNotDispatchWhenDurableRemovalFails() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, persistence) = makeAppState(sendBehavior: .autoSend, seed: [draft])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        await appState.approveDraft(draft)

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDraftCount, 1)
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.identity), [draft.identity])
        XCTAssertTrue(notifier.removedIdentities.isEmpty)
        XCTAssertNotNil(appState.approvalError)
    }

    func testApproveBlocksDraftFromDifferentAccount() async {
        let draft = pendingDraft(sourceAccountEmail: "old@gmail.com")
        let (appState, provider, notifier, persistence) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDraftCount, 1)
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.identity), [draft.identity])
        XCTAssertTrue(notifier.removedIdentities.isEmpty)
        XCTAssertEqual(appState.approvalError, "This draft was generated for a different email account.")
    }

    func testDenyDiscardsWithoutSendingAndClearsNotification() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, persistence) = makeAppState(seed: [draft])

        appState.denyDraft(draft)

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertEqual(notifier.removedIdentities, [draft.identity])
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
    }

    func testOnlyTargetedDraftIsRemoved() async {
        let keep = pendingDraft(id: 1)
        let approve = pendingDraft(id: 2)
        let (appState, _, _, _) = makeAppState(seed: [keep, approve])

        await appState.approveDraft(approve)

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
    }

    // MARK: - Notification routing

    func testNotificationApproveActionApprovesDraft() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await notifier.fireAction(.approve, identity: draft.identity)

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(provider.sentEnvelope)
    }

    func testNotificationApproveActionWaitsForApprovalToFinish() async {
        let draft = pendingDraft()
        let (appState, provider, _, _) = makeAppStateWithSuspendedSend(seed: [draft])
        let probe = NotificationActionProbe()

        let route = Task {
            await appState.handleNotificationAction(.approve, identity: draft.identity)
            await probe.markComplete()
        }
        await fulfillment(of: [provider.didStartSend], timeout: 1)
        await Task.yield()

        XCTAssertFalse(probe.isComplete)
        XCTAssertEqual(provider.sentMessageCount, 1)
        XCTAssertTrue(appState.approvingDraftIDs.contains(draft.identity))

        provider.completeSend(with: .success(()))
        await route.value

        XCTAssertTrue(probe.isComplete)
        XCTAssertFalse(appState.approvingDraftIDs.contains(draft.identity))
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testNotificationDenyActionDiscardsDraft() async {
        let draft = pendingDraft()
        let (appState, _, notifier, _) = makeAppState(seed: [draft])

        await notifier.fireAction(.deny, identity: draft.identity)

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testNotificationOpenActionInvokesReviewHandler() async {
        let (appState, _, notifier, _) = makeAppState(seed: [pendingDraft()])
        var opened = false
        appState.openReviewHandler = { opened = true }

        await notifier.fireAction(.open, identity: "anything")

        XCTAssertTrue(opened)
    }

    func testUnknownIdentityActionIsIgnored() async {
        let (appState, _, notifier, _) = makeAppState(seed: [pendingDraft()])

        await notifier.fireAction(.deny, identity: "missing")

        XCTAssertEqual(appState.pendingDrafts.count, 1)
    }

    func testInlineNotificationActionsRequireAuthentication() {
        let actions = UserNotificationService.draftActions()
        let approve = actions.first { $0.identifier == UserNotificationService.approveActionIdentifier }
        let deny = actions.first { $0.identifier == UserNotificationService.denyActionIdentifier }

        XCTAssertTrue(approve?.options.contains(.authenticationRequired) ?? false)
        XCTAssertTrue(deny?.options.contains(.authenticationRequired) ?? false)
        XCTAssertTrue(deny?.options.contains(.destructive) ?? false)
    }

    func testInlineNotificationCopyReflectsSendBehavior() {
        let sendActions = UserNotificationService.draftActions(for: .autoSend)
        let saveActions = UserNotificationService.draftActions(for: .saveAsDraft)
        let sendApprove = sendActions.first { $0.identifier == UserNotificationService.approveActionIdentifier }
        let saveApprove = saveActions.first { $0.identifier == UserNotificationService.approveActionIdentifier }

        XCTAssertEqual(sendApprove?.title, "Send Now")
        XCTAssertEqual(saveApprove?.title, "Save Draft")
        XCTAssertEqual(
            UserNotificationService.notificationBody(replyBody: "Thursday works!", sendBehavior: .autoSend),
            "Approve sends this reply now. Thursday works!"
        )
        XCTAssertEqual(
            UserNotificationService.notificationBody(replyBody: "Thursday works!", sendBehavior: .saveAsDraft),
            "Approve saves this as a draft. Thursday works!"
        )
        XCTAssertNotEqual(
            UserNotificationService.categoryIdentifier(for: .autoSend),
            UserNotificationService.categoryIdentifier(for: .saveAsDraft)
        )
    }

    // MARK: - Enqueue posts a notification (and captures the incoming body)

    func testWatcherEnqueuePostsNotificationWithIncomingBody() async {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        // Seed a completed baseline with a low UID cutoff so message 7 counts as
        // newly arrived (past the cold-start baseline) and gets drafted.
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        processed.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 1, uidValidity: nil)
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            processedMessages: processed
        )
        let message = MailMessage(
            id: 7,
            from: MailAddress(name: "Alice", email: "alice@x.com"),
            subject: "Ping",
            date: "",
            messageID: "<7@x.com>"
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: .success([message]),
            bodyResult: .success(Data("Can you review this?".utf8))
        )
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "Sure!"))),
            notifier: notifier
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(notifier.notifiedDrafts.map(\.id), [7])
        XCTAssertEqual(appState.pendingDrafts.first?.incomingBody, "Can you review this?")
    }
}
