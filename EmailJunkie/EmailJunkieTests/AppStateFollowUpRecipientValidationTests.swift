import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateFollowUpRecipientValidationTests: XCTestCase {

    private func authoredDraft(recipients: [MailAddress]) -> Draft {
        Draft(
            id: 51,
            sourceUIDValidity: nil,
            sourceAccountEmail: "me@gmail.com",
            sourceMailHost: "imap.gmail.com",
            sourceMailPort: 993,
            sourceMailbox: nil,
            sourceSubject: "Post-call follow-up",
            sourceFrom: recipients.first,
            sourceReplyTo: nil,
            sourceMessageID: nil,
            incomingBody: "Marcus: recap.",
            replySubject: "Post-call follow-up",
            body: "Thanks for the call.",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            authoredRecipients: recipients
        )
    }

    private func makeAppState(seed drafts: [Draft])
        -> (AppState, FakeAppMailProvider, AppStateMemoryPersistence) {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        ), pendingDrafts: drafts)
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(seed: [
                .mailAppPassword: "app-pw",
                .llmAPIKey(provider: "anthropic"): "sk-live"
            ]),
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier()
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, provider, persistence)
    }

    func testRecipientEditFlagsMalformedExtraEntry() {
        let parsed = AppState.parseRecipientEdit("alice@example.com, bob@")

        XCTAssertEqual(parsed.recipients.map(\.email), ["alice@example.com"])
        XCTAssertTrue(parsed.hasInvalidEntries)
    }

    func testRecipientEditFlagsMalformedDisplayEntry() {
        let parsed = AppState.parseRecipientEdit("Alice <alice@example.com> bob@")

        XCTAssertEqual(parsed.recipients.map(\.email), [])
        XCTAssertTrue(parsed.hasInvalidEntries)
    }

    func testRecipientEditTrimsAddressInsideDisplayNameBrackets() {
        let parsed = AppState.parseRecipientEdit("Alice <alice@example.com >")

        XCTAssertEqual(parsed.recipients.map(\.email), ["alice@example.com"])
        XCTAssertFalse(parsed.hasInvalidEntries)
    }

    func testRecipientEditRejectsWhitespaceInsideDisplayNameBrackets() {
        let parsed = AppState.parseRecipientEdit("Alice <alice@example.com Bob>")

        XCTAssertEqual(parsed.recipients.map(\.email), [])
        XCTAssertTrue(parsed.hasInvalidEntries)
    }

    func testMalformedRecipientEditBlocksNotificationApproval() async {
        let draft = authoredDraft(recipients: [MailAddress(email: "alice@example.com")])
        let (appState, provider, _) = makeAppState(seed: [draft])
        var openedReview = false
        appState.openReviewHandler = { openedReview = true }
        appState.notePendingDraftRecipientEdit(
            draft,
            recipientEdit: AppState.parseRecipientEdit("alice@example.com, bob@")
        )

        await appState.handleNotificationAction(.approve(.autoSend), identity: draft.identity)

        XCTAssertTrue(openedReview)
        XCTAssertNil(provider.sentEnvelope)
        XCTAssertEqual(appState.pendingDrafts.first?.authoredRecipients?.map(\.email), ["alice@example.com"])
        XCTAssertTrue(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
        XCTAssertTrue(appState.pendingDraftInvalidRecipientEditIDs.contains(draft.identity))
        XCTAssertNotNil(appState.approvalError)
    }

    func testMalformedRecipientEditBlocksReviewApproval() async {
        let draft = authoredDraft(recipients: [MailAddress(email: "alice@example.com")])
        let (appState, provider, _) = makeAppState(seed: [draft])
        appState.notePendingDraftRecipientEdit(
            draft,
            recipientEdit: AppState.parseRecipientEdit("alice@example.com, bob@")
        )

        await appState.approvePendingDraft(draft, withEditedBody: draft.body)

        XCTAssertNil(provider.sentEnvelope)
        XCTAssertEqual(appState.pendingDrafts.first?.authoredRecipients?.map(\.email), ["alice@example.com"])
        XCTAssertTrue(appState.pendingDraftInvalidRecipientEditIDs.contains(draft.identity))
        XCTAssertNotNil(appState.approvalError)
    }
}
