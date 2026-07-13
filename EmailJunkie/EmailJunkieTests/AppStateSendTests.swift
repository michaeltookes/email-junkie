import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateSendTests: XCTestCase {

    private func draft(replyTo: MailAddress? = nil) -> Draft {
        Draft(
            id: 5,
            sourceUIDValidity: 1,
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
