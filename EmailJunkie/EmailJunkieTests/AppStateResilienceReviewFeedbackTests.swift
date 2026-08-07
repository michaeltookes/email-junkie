import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateResilienceReviewFeedbackTests: XCTestCase {

    private func pendingDraft(id: UInt32 = 1, subject: String = "Lunch?") -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: subject,
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: \(subject)",
            body: "Thursday works!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func message(
        id: UInt32,
        subject: String,
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 10,
            from: MailAddress(email: "alice@example.com"),
            to: [],
            subject: subject,
            date: "",
            inReplyTo: inReplyTo,
            messageID: messageID
        )
    }

    private func searchResult(_ messages: [MailMessage]) -> MailSearchResult {
        MailSearchResult(messages: messages, totalMatches: messages.count, offset: 0, hasMore: false)
    }

    private func makeAppState(
        online: Bool = true,
        reachabilityHasCurrentPath: Bool = true,
        sendBehavior: SendBehavior = .autoSend,
        sendDelaySeconds: Int = 0,
        appendResults: [Result<Void, MailError>] = [.success(())],
        searchResult: Result<MailSearchResult, MailError> = .failure(.commandFailed("search unsupported")),
        seed drafts: [Draft] = []
    ) -> (AppState, ResilienceMailProvider, FakeReachabilityMonitor, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6",
                sendBehavior: sendBehavior.rawValue,
                sendDelaySeconds: sendDelaySeconds
            ),
            pendingDrafts: drafts
        )
        let provider = ResilienceMailProvider(
            sendResults: [.success(())],
            appendResults: appendResults,
            searchResult: searchResult
        )
        let reachability = FakeReachabilityMonitor(
            isOnline: online,
            hasCurrentPath: reachabilityHasCurrentPath
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier(),
            reachability: reachability
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        appState.retryRunner = .immediate
        return (appState, provider, reachability, persistence)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000)
            await Task.yield()
        }
    }

    func testOfflineApprovalQueuesBeforeStartingCountdown() async {
        let draft = pendingDraft()
        let (appState, provider, _, persistence) = makeAppState(
            online: false,
            sendDelaySeconds: 10,
            seed: [draft]
        )

        await appState.approveDraft(draft)

        let expectedIntent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
        XCTAssertTrue(appState.sendCountdownTasks.isEmpty)
        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.offlineQueuedDispatch[draft.identity], expectedIntent)
        XCTAssertTrue(appState.isWaitingForNetwork(draft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, expectedIntent)
    }

    func testLaunchWaitsForInitialReachabilityBeforeDrainingRestoredQueue() async {
        var queuedDraft = pendingDraft()
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        queuedDraft.offlineQueuedDispatch = intent
        let (appState, provider, reachability, persistence) = makeAppState(
            online: true,
            reachabilityHasCurrentPath: false,
            seed: [queuedDraft]
        )

        appState.startReachabilityMonitoring()
        await Task.yield()

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)

        reachability.setOnline(false)
        await Task.yield()

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)

        reachability.setOnline(true)
        await waitUntil { appState.pendingDrafts.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 1)
        XCTAssertTrue(appState.offlineQueuedDispatch.isEmpty)
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
    }

    func testReconnectKeepsQueuedDispatchDurableDuringAutoSendCountdown() async {
        var queuedDraft = pendingDraft()
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        queuedDraft.offlineQueuedDispatch = intent
        let (appState, provider, _, persistence) = makeAppState(
            online: true,
            sendDelaySeconds: 10,
            seed: [queuedDraft]
        )
        appState.sendCountdownTickNanoseconds = 60_000_000_000

        appState.startReachabilityMonitoring()
        await waitUntil { appState.pendingSendCountdowns[queuedDraft.identity] == 10 }

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)
    }

    func testOverlappingReconnectDrainKeepsIntentWhileApprovalInFlight() async {
        var queuedDraft = pendingDraft()
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend, force: true)
        queuedDraft.offlineQueuedDispatch = intent
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6",
                sendBehavior: SendBehavior.autoSend.rawValue
            ),
            pendingDrafts: [queuedDraft]
        )
        let provider = SuspendedSendMailProvider()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier(),
            reachability: FakeReachabilityMonitor()
        )
        appState.pendingDrafts = [queuedDraft]
        appState.pendingDraftCount = 1
        appState.retryRunner = .immediate

        let firstDrain = Task { await appState.resumeQueuedDraftsAfterReconnect() }
        await fulfillment(of: [provider.didStartSend], timeout: 1)

        XCTAssertTrue(appState.approvingDraftIDs.contains(queuedDraft.identity))
        await appState.resumeQueuedDraftsAfterReconnect()

        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)

        provider.completeSend(with: .success(()))
        await firstDrain.value
        await waitUntil { appState.pendingDrafts.isEmpty }

        XCTAssertTrue(appState.offlineQueuedDispatch.isEmpty)
        XCTAssertFalse(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
    }

    func testReconnectSaveFailureClearsQueuedIntentWhenReachabilityDropsAfterAppendAttempt() async {
        var draft = pendingDraft()
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .saveAsDraft)
        draft.offlineQueuedDispatch = intent
        let (appState, provider, reachability, persistence) = makeAppState(
            online: false,
            sendBehavior: .saveAsDraft,
            appendResults: [.failure(.connectionFailed("offline"))],
            seed: [draft]
        )
        provider.beforeAppendResult = {
            await MainActor.run { reachability.setOnline(false) }
        }

        reachability.setOnline(true)
        await waitUntil { provider.appendCallCount == 1 && !appState.isWaitingForNetwork(draft.identity) }

        XCTAssertEqual(provider.appendCallCount, 1, "IMAP APPEND is not retried because success can be ambiguous")
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertTrue(appState.offlineQueuedDispatch.isEmpty)
        XCTAssertNil(persistence.loadPendingDrafts().first?.offlineQueuedDispatch)
        XCTAssertTrue(appState.activityEvents.contains { $0.kind == .saveFailed })
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .queuedOffline })
        XCTAssertNotNil(appState.approvalError)
    }

    func testCancelReconnectCountdownClearsQueuedIntent() async {
        var draft = pendingDraft()
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        draft.offlineQueuedDispatch = intent
        let (appState, provider, _, persistence) = makeAppState(
            online: true,
            sendDelaySeconds: 10,
            seed: [draft]
        )
        appState.sendCountdownTickNanoseconds = 60_000_000_000

        await appState.resumeQueuedDraftsAfterReconnect()
        XCTAssertEqual(appState.pendingSendCountdowns[draft.identity], 10)
        XCTAssertEqual(appState.offlineQueuedDispatch[draft.identity], intent)

        appState.cancelSendCountdown(draft)

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
        XCTAssertTrue(appState.sendCountdownTasks.isEmpty)
        XCTAssertNil(appState.offlineQueuedDispatch[draft.identity])
        XCTAssertFalse(appState.isWaitingForNetwork(draft.identity))
        XCTAssertNil(persistence.loadPendingDrafts().first?.offlineQueuedDispatch)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertNil(appState.approvalError)
        XCTAssertEqual(appState.activityEvents.first?.kind, .sendCanceled)
    }

    func testCancelReconnectCountdownKeepsQueuedIntentWhenPersistenceFails() async {
        var draft = pendingDraft()
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        draft.offlineQueuedDispatch = intent
        let (appState, provider, _, persistence) = makeAppState(
            online: true,
            sendDelaySeconds: 10,
            seed: [draft]
        )
        appState.sendCountdownTickNanoseconds = 60_000_000_000

        await appState.resumeQueuedDraftsAfterReconnect()
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied
        appState.cancelSendCountdown(draft)

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
        XCTAssertEqual(appState.offlineQueuedDispatch[draft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(draft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)
        XCTAssertTrue(appState.approvalError?.contains("settings write denied") ?? false)
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .sendCanceled })
    }

    func testQueuedDispatchClearsAfterReconnectCountdownDispatchSucceeds() async {
        var queuedDraft = pendingDraft()
        queuedDraft.offlineQueuedDispatch = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        let (appState, provider, _, persistence) = makeAppState(
            online: true,
            sendDelaySeconds: 1,
            seed: [queuedDraft]
        )
        appState.sendCountdownTickNanoseconds = 1

        appState.startReachabilityMonitoring()
        await waitUntil { appState.pendingDrafts.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 1)
        XCTAssertTrue(appState.offlineQueuedDispatch.isEmpty)
        XCTAssertFalse(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
        XCTAssertTrue(persistence.loadApprovedDraftIdentities().contains(queuedDraft.identity))
    }

    func testReconnectClearsQueuedDispatchWhenStaleWarningNeedsManualReview() async {
        var queuedDraft = pendingDraft(id: 5)
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        queuedDraft.offlineQueuedDispatch = intent
        let staleThread = searchResult([
            message(id: 5, subject: "Lunch?", messageID: "<orig@example.com>"),
            message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@example.com>", messageID: "<new@example.com>")
        ])
        let (appState, provider, reachability, persistence) = makeAppState(
            online: false,
            searchResult: .success(staleThread),
            seed: [queuedDraft]
        )

        reachability.setOnline(true)
        await waitUntil { appState.pendingStaleWarnings[queuedDraft.identity] != nil }

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertGreaterThan(provider.searchCallCount, 0)
        XCTAssertNil(appState.offlineQueuedDispatch[queuedDraft.identity])
        XCTAssertFalse(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertNil(persistence.loadPendingDrafts().first?.offlineQueuedDispatch)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [queuedDraft.identity])
    }

    func testCancelQueuedDispatchRollsBackWhenPersistenceFails() {
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        var queuedDraft = pendingDraft()
        queuedDraft.offlineQueuedDispatch = intent
        let (appState, _, _, persistence) = makeAppState(online: false, seed: [queuedDraft])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        appState.cancelQueuedDraftDispatch(queuedDraft.identity)

        XCTAssertEqual(appState.pendingDrafts.first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)
        XCTAssertTrue(appState.approvalError?.contains("settings write denied") ?? false)
    }
}
