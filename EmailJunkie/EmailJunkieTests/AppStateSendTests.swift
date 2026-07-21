import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateSendTests: XCTestCase {

    private func draft(
        replyTo: MailAddress? = nil,
        sourceAccountEmail: String? = "me@gmail.com",
        sourceMailbox: String? = Mailbox.inbox.imapName
    ) -> Draft {
        Draft(
            id: 5,
            sourceUIDValidity: 1,
            sourceAccountEmail: sourceAccountEmail,
            sourceMailbox: sourceMailbox,
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: replyTo,
            sourceMessageID: "<orig@example.com>",
            replySubject: "Re: Lunch?",
            body: "Sounds good!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAppState(
        sendBehavior: SendBehavior = .autoSend,
        sendResult: Result<Void, MailError> = .success(()),
        appendResult: Result<Void, MailError> = .success(()),
        draft: Draft? = nil
    ) -> (AppState, FakeAppMailProvider) {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: sendBehavior.rawValue
        ))
        let provider = FakeAppMailProvider(
            result: .success(()),
            appendResult: appendResult,
            sendResult: sendResult
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.mailAppPassword = "app-pw"
        appState.generatedDraft = draft ?? self.draft()
        return (appState, provider)
    }

    func testSendBehaviorLoadedFromSettings() {
        let (appState, _) = makeAppState(sendBehavior: .autoSend)
        XCTAssertEqual(appState.sendBehavior, .autoSend)
    }

    func testApproveWithAutoSendSendsOverSMTP() async {
        let (appState, provider) = makeAppState(sendBehavior: .autoSend)

        await appState.approveGeneratedDraft()

        XCTAssertEqual(provider.sentEnvelope?.sender, "me@gmail.com")
        XCTAssertEqual(provider.sentEnvelope?.recipients, ["alice@example.com"])
        XCTAssertNil(provider.appendedRFC822, "should not have saved a draft")
        XCTAssertEqual(appState.draftSentMessage, "Sent.")
        XCTAssertNil(appState.draftError)
        XCTAssertFalse(appState.isSendingDraft)
        XCTAssertNil(appState.generatedDraft, "draft cleared after a successful send")

        let rfc822 = String(data: provider.sentRFC822 ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(rfc822.contains("Subject: Re: Lunch?"))
        XCTAssertTrue(rfc822.contains("In-Reply-To: <orig@example.com>"))
    }

    func testPreviewApprovalSendsDisplayedDraftWhenGeneratedDraftChanges() async throws {
        var displayedDraft = draft()
        displayedDraft.id = 5
        displayedDraft.sourceFrom = MailAddress(name: "Alice", email: "alice@example.com")
        displayedDraft.replySubject = "Re: Alice"
        displayedDraft.body = "Reply to Alice"

        var otherWindowDraft = draft()
        otherWindowDraft.id = 9
        otherWindowDraft.sourceFrom = MailAddress(name: "Bob", email: "bob@example.com")
        otherWindowDraft.replySubject = "Re: Bob"
        otherWindowDraft.body = "Reply to Bob"

        let (appState, provider) = makeAppState(sendBehavior: .autoSend, draft: otherWindowDraft)

        let confirmation = try await appState.approveDraftPreview(displayedDraft)

        XCTAssertEqual(confirmation, "Sent.")
        XCTAssertEqual(provider.sentEnvelope?.recipients, ["alice@example.com"])
        XCTAssertEqual(appState.generatedDraft, otherWindowDraft)
        let rfc822 = String(data: provider.sentRFC822 ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(rfc822.contains("Subject: Re: Alice"))
        XCTAssertFalse(rfc822.contains("Subject: Re: Bob"))
        XCTAssertFalse(rfc822.contains("bob@example.com"))
    }

    func testPreviewApprovalRejectsDraftAfterAccountChanges() async {
        let staleDraft = draft(sourceAccountEmail: "old@gmail.com")
        let (appState, provider) = makeAppState(sendBehavior: .autoSend, draft: staleDraft)

        do {
            _ = try await appState.approveDraftPreview(staleDraft)
            XCTFail("Expected preview approval to reject a draft from another account")
        } catch let error as DraftDispatchError {
            XCTAssertEqual(error, .accountMismatch)
            XCTAssertEqual(AppState.draftMessage(for: error), "This draft was generated for a different email account.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertNil(appState.generatedDraft)
    }

    func testPreviewApprovalRejectsDraftFromOutgoingMailbox() async {
        let outgoingDraft = draft(sourceMailbox: Mailbox.sent.imapName)
        let (appState, provider) = makeAppState(sendBehavior: .autoSend, draft: outgoingDraft)

        do {
            _ = try await appState.approveDraftPreview(outgoingDraft)
            XCTFail("Expected preview approval to reject drafts from outgoing mailboxes")
        } catch let error as DraftError {
            XCTAssertEqual(error, .unsupportedSourceMailbox)
            XCTAssertEqual(AppState.draftMessage(for: error), "Draft replies are only available for incoming mail.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertNil(appState.generatedDraft)
    }

    func testApproveWithAutoSendIgnoresSecondApprovalWhileSendInFlight() async {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue
        ))
        let provider = SuspendedSendMailProvider()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.mailAppPassword = "app-pw"
        appState.generatedDraft = draft()

        let firstApproval = Task { await appState.approveGeneratedDraft() }
        await fulfillment(of: [provider.didStartSend], timeout: 1)
        XCTAssertTrue(appState.isSendingDraft)

        await appState.approveGeneratedDraft()

        XCTAssertEqual(provider.sentMessageCount, 1)
        XCTAssertEqual(provider.sentEnvelope?.recipients, ["alice@example.com"])

        provider.completeSend(with: .success(()))
        await firstApproval.value

        XCTAssertEqual(provider.sentMessageCount, 1)
        XCTAssertEqual(appState.draftSentMessage, "Sent.")
        XCTAssertFalse(appState.isSendingDraft)
        XCTAssertNil(appState.generatedDraft)
    }

    func testApproveWithSaveAsDraftAppendsInsteadOfSending() async {
        let (appState, provider) = makeAppState(sendBehavior: .saveAsDraft)

        await appState.approveGeneratedDraft()

        XCTAssertEqual(provider.appendedMailbox, .drafts)
        XCTAssertNil(provider.sentRFC822, "should not have sent over SMTP")
        XCTAssertNotNil(appState.draftSavedMessage)
        XCTAssertNil(appState.draftSentMessage)
    }

    func testSendPrefersReplyToRecipient() async {
        let (appState, provider) = makeAppState(
            draft: draft(replyTo: MailAddress(name: "Team", email: "team@example.com"))
        )

        await appState.sendGeneratedDraft()

        XCTAssertEqual(provider.sentEnvelope?.recipients, ["team@example.com"])
    }

    func testSendFailureSurfacesError() async {
        let (appState, _) = makeAppState(sendResult: .failure(.authenticationFailed("bad app password")))

        await appState.sendGeneratedDraft()

        XCTAssertNil(appState.draftSentMessage)
        XCTAssertNotNil(appState.draftError)
        XCTAssertFalse(appState.isSendingDraft)
        XCTAssertNotNil(appState.generatedDraft, "draft kept on failure so it can be retried")
    }

    func testSendWithoutGeneratedDraftIsNoOp() async {
        let (appState, provider) = makeAppState()
        appState.generatedDraft = nil

        await appState.sendGeneratedDraft()

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(appState.draftSentMessage)
    }
}
