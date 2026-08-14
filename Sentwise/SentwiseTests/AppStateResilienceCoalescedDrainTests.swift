import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateResilienceCoalescedDrainTests: XCTestCase {

    private func pendingDraft(id: UInt32, subject: String) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: subject,
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<\(id)@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: \(subject)",
            body: "Thursday works!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testCoalescedReconnectDrainProcessesQueuedWorkAddedWhileRunning() async {
        var firstDraft = pendingDraft(id: 1, subject: "First")
        let firstIntent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        firstDraft.offlineQueuedDispatch = firstIntent

        var secondDraft = pendingDraft(id: 2, subject: "Second")
        let secondIntent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend, force: true)
        secondDraft.offlineQueuedDispatch = secondIntent

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
                    sendBehavior: SendBehavior.autoSend.rawValue,
                    sendDelaySeconds: 0
                ),
                pendingDrafts: [firstDraft]
            )
        let provider = ResilienceMailProvider(sendResults: [.success(()), .success(())])
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier(),
            reachability: FakeReachabilityMonitor()
        )
        appState.pendingDrafts = [firstDraft]
        appState.pendingDraftCount = 1
        appState.retryRunner = .immediate

        provider.beforeSendResult = {
            await MainActor.run {
                guard provider.sendCallCount == 1 else { return }
                appState.pendingDrafts.append(secondDraft)
                appState.pendingDraftCount = appState.pendingDrafts.count
                appState.offlineQueuedDispatch[secondDraft.identity] = secondIntent
                appState.draftsWaitingForNetwork.insert(secondDraft.identity)
                try? persistence.savePendingDraftsSync(appState.pendingDrafts)
                appState.needsQueuedDraftDrainAfterCurrent = true
            }
        }

        await appState.resumeQueuedDraftsAfterReconnect()

        XCTAssertEqual(provider.sendCallCount, 2)
        XCTAssertTrue(appState.offlineQueuedDispatch.isEmpty)
        XCTAssertTrue(appState.draftsWaitingForNetwork.isEmpty)
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
    }
}
