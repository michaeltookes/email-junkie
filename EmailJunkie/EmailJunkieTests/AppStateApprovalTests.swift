import EmailJunkieMail
import XCTest
@testable import EmailJunkie

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
        let (appState, _, notifier, _) = makeAppState(
            sendBehavior: .autoSend,
            sendResult: .failure(.authenticationFailed("bad app password")),
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertNotNil(appState.approvalError)
        XCTAssertTrue(notifier.removedIdentities.isEmpty)
        XCTAssertFalse(appState.approvingDraftIDs.contains(draft.identity))
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

        notifier.fireAction(.approve, identity: draft.identity)
        // The approve runs in a detached Task; yield until it settles.
        for _ in 0..<50 where !appState.pendingDrafts.isEmpty {
            await Task.yield()
        }

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(provider.sentEnvelope)
    }

    func testNotificationDenyActionDiscardsDraft() {
        let draft = pendingDraft()
        let (appState, _, notifier, _) = makeAppState(seed: [draft])

        notifier.fireAction(.deny, identity: draft.identity)

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testNotificationOpenActionInvokesReviewHandler() {
        let (appState, _, notifier, _) = makeAppState(seed: [pendingDraft()])
        var opened = false
        appState.openReviewHandler = { opened = true }

        notifier.fireAction(.open, identity: "anything")

        XCTAssertTrue(opened)
    }

    func testUnknownIdentityActionIsIgnored() {
        let (appState, _, notifier, _) = makeAppState(seed: [pendingDraft()])

        notifier.fireAction(.deny, identity: "missing")

        XCTAssertEqual(appState.pendingDrafts.count, 1)
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
