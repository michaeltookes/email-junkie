import EmailJunkieMail
import XCTest
@testable import EmailJunkie

/// Integration tests for item 27: the offline queue, reachability-driven pause/
/// resume, send retry, and the no-duplicate-sends invariant.
@MainActor
final class AppStateResilienceTests: XCTestCase {

    // MARK: - Fixtures

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

    private func makeAppState(
        online: Bool = true,
        sendBehavior: SendBehavior = .autoSend,
        sendDelaySeconds: Int = 0,
        sendResults: [Result<Void, MailError>] = [.success(())],
        fetchResult: Result<[MailMessage], MailError> = .success([]),
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
        let provider = ResilienceMailProvider(sendResults: sendResults, fetchResult: fetchResult)
        let reachability = FakeReachabilityMonitor(isOnline: online)
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

    // MARK: - Offline queue

    func testApproveWhileOfflineQueuesWithoutSending() async {
        let draft = pendingDraft()
        let (appState, provider, _, persistence) = makeAppState(online: false, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sendCallCount, 0, "no send should be attempted while offline")
        XCTAssertTrue(appState.isWaitingForNetwork(draft.identity))
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1], "draft stays queued")
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.id), [1], "and remains persisted for restart survival")
        XCTAssertEqual(appState.activityEvents.map(\.kind), [.queuedOffline])
        XCTAssertFalse(persistence.loadApprovedDraftIdentities().contains(draft.identity), "not finalized")
    }

    func testReconnectDrainsQueuedDraftExactlyOnce() async {
        let draft = pendingDraft()
        let (appState, provider, reachability, persistence) = makeAppState(online: false, seed: [draft])

        await appState.approveDraft(draft)
        XCTAssertEqual(provider.sendCallCount, 0)

        reachability.setOnline(true)
        await waitUntil { appState.pendingDrafts.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 1, "exactly one send on reconnect — no duplicate")
        XCTAssertFalse(appState.isWaitingForNetwork(draft.identity))
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertTrue(persistence.loadApprovedDraftIdentities().contains(draft.identity), "finalized with a tombstone")
        XCTAssertTrue(appState.activityEvents.contains { $0.kind == .resumedOnline })
        XCTAssertTrue(appState.activityEvents.contains { $0.kind == .approvedSent })
    }

    func testDenyWhileOfflineClearsQueueEntry() async {
        let draft = pendingDraft()
        let (appState, provider, reachability, _) = makeAppState(online: false, seed: [draft])

        await appState.approveDraft(draft)
        XCTAssertTrue(appState.isWaitingForNetwork(draft.identity))

        appState.denyDraft(draft)
        XCTAssertFalse(appState.isWaitingForNetwork(draft.identity))
        XCTAssertTrue(appState.pendingDrafts.isEmpty)

        // Reconnecting must not resurrect a denied draft.
        reachability.setOnline(true)
        await waitUntil { appState.activityEvents.contains { $0.kind == .resumedOnline } }
        XCTAssertEqual(provider.sendCallCount, 0)
    }

    func testAccountSwitchClearsOfflineQueue() async {
        let draft = pendingDraft()
        let (appState, _, _, _) = makeAppState(online: false, seed: [draft])
        await appState.approveDraft(draft)
        XCTAssertFalse(appState.draftsWaitingForNetwork.isEmpty)

        appState.clearAllOfflineQueueEntries()

        XCTAssertTrue(appState.draftsWaitingForNetwork.isEmpty)
        XCTAssertTrue(appState.offlineQueuedDispatch.isEmpty)
    }

    // MARK: - Reachability drives the poll loop

    func testPollIsSkippedWhileOffline() async {
        let (appState, provider, _, _) = makeAppState(online: false, fetchResult: .success([]))
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(provider.fetchCallCount, 0, "offline poll must not fetch")
    }

    func testReconnectRecordsResumedOnlineEvent() async {
        let (appState, _, reachability, _) = makeAppState(online: false)

        reachability.setOnline(true)

        XCTAssertTrue(appState.isOnline)
        XCTAssertEqual(appState.activityEvents.map(\.kind), [.resumedOnline])
    }

    // MARK: - Send retry + no-duplicate invariant

    func testTransientSendRetriesThenSucceedsWithoutDuplicate() async {
        let draft = pendingDraft()
        let (appState, provider, _, persistence) = makeAppState(
            sendResults: [
                .failure(.connectionFailed("reset")),
                .failure(.connectionFailed("reset")),
                .success(())
            ],
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sendCallCount, 3, "retried the two transient failures, then succeeded")
        XCTAssertEqual(provider.distinctRFC822Count, 1, "the same message is resent — no distinct duplicate")
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertTrue(persistence.loadApprovedDraftIdentities().contains(draft.identity))
        XCTAssertEqual(appState.activityEvents.map(\.kind), [.approvedSent])
    }

    func testAmbiguousSendIsNotRetriedAndDraftStaysPending() async {
        let draft = pendingDraft()
        let (appState, provider, _, persistence) = makeAppState(
            sendResults: [.failure(.sendInterruptedAfterSubmission("dropped after DATA"))],
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sendCallCount, 1, "an ambiguous post-DATA failure must never be auto-retried")
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1], "draft stays pending for a manual decision")
        XCTAssertFalse(persistence.loadApprovedDraftIdentities().contains(draft.identity))
        XCTAssertEqual(appState.activityEvents.map(\.kind), [.sendFailed])
        XCTAssertNotNil(appState.approvalError)
        XCTAssertTrue(
            appState.approvalError?.contains("may already have gone out") ?? false,
            "the user is warned the message may have been sent: \(appState.approvalError ?? "nil")"
        )
    }

    func testAuthSendFailureIsNotRetriedAndRecordsAuthFailed() async {
        let draft = pendingDraft()
        let (appState, provider, _, _) = makeAppState(
            sendResults: [.failure(.authenticationFailed("bad app password"))],
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sendCallCount, 1, "auth failures are never retried")
        XCTAssertEqual(appState.activityEvents.map(\.kind), [.authFailed])
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
    }
}

/// A mail provider whose send results are scripted (consumed in order, the last
/// repeating) so retry behavior can be exercised deterministically. Records the
/// distinct RFC822 payloads seen so tests can assert a retry doesn't fabricate a
/// second, different message.
final class ResilienceMailProvider: MailProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var sendResults: [Result<Void, MailError>]
    private let fetchResult: Result<[MailMessage], MailError>
    private var seenRFC822: [Data] = []
    private(set) var sendCallCount = 0
    private(set) var fetchCallCount = 0

    init(sendResults: [Result<Void, MailError>], fetchResult: Result<[MailMessage], MailError> = .success([])) {
        self.sendResults = sendResults
        self.fetchResult = fetchResult
    }

    var distinctRFC822Count: Int {
        lock.lock(); defer { lock.unlock() }
        var unique: [Data] = []
        for payload in seenRFC822 where !unique.contains(payload) { unique.append(payload) }
        return unique.count
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int
    ) async throws -> [MailMessage] {
        lock.lock(); fetchCallCount += 1; lock.unlock()
        return try fetchResult.get()
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data { Data("Please advise.".utf8) }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {}

    func sendMessage(
        _ credentials: MailAccountCredentials, rfc822: Data, envelope: SMTPEnvelope
    ) async throws {
        lock.lock()
        sendCallCount += 1
        seenRFC822.append(rfc822)
        let result = sendResults.count > 1 ? sendResults.removeFirst() : (sendResults.first ?? .success(()))
        lock.unlock()
        try result.get()
    }
}
