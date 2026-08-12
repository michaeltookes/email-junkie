import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateFollowUpTests: XCTestCase {

    private func makeAppState(
        sendBehavior: SendBehavior = .autoSend,
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "Hi team,\n\nGreat call — I'll send the deck Friday.")),
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
            sendBehavior: sendBehavior.rawValue,
            sendDelaySeconds: 0
        ), pendingDrafts: drafts)
        let provider = FakeAppMailProvider(result: .success(()))
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()), completion: completion),
            notifier: notifier
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, provider, notifier, persistence)
    }

    private func authoredDraft(recipients: [MailAddress], id: UInt32 = 7) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: nil,
            sourceAccountEmail: "me@gmail.com",
            sourceSubject: "Follow-up: Sync",
            sourceFrom: recipients.first,
            sourceReplyTo: nil,
            sourceMessageID: nil,
            replySubject: "Follow-up: Sync",
            body: "Thanks for the call.",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            authoredRecipients: recipients
        )
    }

    // MARK: - Creating follow-ups

    func testCreateFollowUpEnqueuesAuthoredDraftAndNotifies() async throws {
        let (appState, _, notifier, persistence) = makeAppState()
        let ingested = try TranscriptIngest.fromPaste("Marcus: Let's ship Friday.\nDana: I'll send the deck.")

        let draft = try await appState.createFollowUp(
            from: ingested,
            recipients: [MailAddress(email: "dana@example.com")]
        )

        XCTAssertTrue(draft.isAuthored)
        XCTAssertEqual(draft.authoredRecipients?.map(\.email), ["dana@example.com"])
        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.pendingDrafts.first?.identity, draft.identity)
        XCTAssertEqual(notifier.notifiedDrafts.last?.identity, draft.identity)
        XCTAssertEqual(persistence.loadPendingDrafts().first?.identity, draft.identity)
    }

    func testCreateFollowUpUsesFollowUpPromptAndTranscript() async throws {
        let llm = FakeLLMProvider(
            result: .success(()),
            completion: .success(LLMResponse(text: "Follow-up body."))
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier()
        )
        let ingested = try TranscriptIngest.fromPaste("Marcus: ship it Friday.")

        _ = try await appState.createFollowUp(from: ingested, recipients: [MailAddress(email: "a@b.com")])

        XCTAssertTrue(llm.lastRequest?.system?.contains("follow-up email") ?? false)
        XCTAssertTrue(llm.lastRequest?.messages.first?.content.contains("ship it Friday") ?? false)
    }

    func testCreateFollowUpDefaultsSubjectFromTitle() async throws {
        let (appState, _, _, _) = makeAppState()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Weekly Sync.txt")
        try "Notes from the call.".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let ingested = try TranscriptIngest.fromFile(url)

        let draft = try await appState.createFollowUp(from: ingested, recipients: [MailAddress(email: "a@b.com")])
        XCTAssertEqual(draft.replySubject, "Follow-up: Weekly Sync")
    }

    // MARK: - Recipients gate

    func testFollowUpWithNoRecipientsEnqueuesButBlocksApproval() async throws {
        let (appState, provider, _, _) = makeAppState(sendBehavior: .autoSend)
        let ingested = try TranscriptIngest.fromPaste("Marcus: recap the call.")

        let draft = try await appState.createFollowUp(from: ingested, recipients: [])
        XCTAssertFalse(draft.hasAuthoredRecipients)

        await appState.approveDraft(draft)

        XCTAssertNil(provider.sentEnvelope, "A recipient-less follow-up must not send")
        XCTAssertEqual(appState.pendingDrafts.count, 1, "It stays queued for the user to add recipients")
        XCTAssertNotNil(appState.approvalError)
    }

    func testUpdatePendingDraftRecipientsPersists() throws {
        let draft = authoredDraft(recipients: [])
        let (appState, _, _, persistence) = makeAppState(seed: [draft])

        let updated = appState.updatePendingDraftRecipients(
            draft,
            to: [MailAddress(email: "dana@example.com"), MailAddress(email: "dana@example.com")]
        )

        XCTAssertEqual(updated?.authoredRecipients?.map(\.email), ["dana@example.com"])
        XCTAssertEqual(appState.pendingDrafts.first?.authoredRecipients?.map(\.email), ["dana@example.com"])
        XCTAssertEqual(persistence.loadPendingDrafts().first?.authoredRecipients?.map(\.email), ["dana@example.com"])
    }

    // MARK: - Dispatch

    func testApproveAuthoredFollowUpSendsToRecipientsWithoutThreading() async throws {
        let draft = authoredDraft(recipients: [MailAddress(email: "dana@example.com")])
        let (appState, provider, _, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sentEnvelope?.recipients, ["dana@example.com"])
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        if let rfc822 = provider.sentRFC822, let text = String(data: rfc822, encoding: .utf8) {
            XCTAssertFalse(text.contains("In-Reply-To"), "Authored follow-ups do not thread")
        }
    }

    // MARK: - Recipient parsing

    func testParseRecipientsHandlesMixedFormats() {
        let parsed = AppState.parseRecipients("dana@example.com, Marcus <marcus@example.com>; a@b.com a@b.com")
        XCTAssertEqual(parsed.map(\.email), ["dana@example.com", "marcus@example.com", "a@b.com"])
    }

    func testParseRecipientsRejectsNonEmails() {
        XCTAssertTrue(AppState.parseRecipients("not-an-email, also nope").isEmpty)
    }

    // MARK: - Watched-folder handler

    func testWatchedTranscriptEnqueuesAuthoredFollowUpWithoutRecipients() async throws {
        let (appState, _, notifier, _) = makeAppState()
        let ingested = try TranscriptIngest.fromPaste("Marcus: recap the call.")

        let accepted = await appState.handleWatchedTranscript(ingested)

        XCTAssertTrue(accepted)
        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertTrue(appState.pendingDrafts.first?.isAuthored ?? false)
        XCTAssertFalse(appState.pendingDrafts.first?.hasAuthoredRecipients ?? true)
        XCTAssertEqual(notifier.notifiedDrafts.last?.identity, appState.pendingDrafts.first?.identity)
    }

    func testWatchedTranscriptWithoutConnectionSetsErrorAndDraftsNothing() async throws {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        // No LLM key/verified model -> not connected -> cannot draft.
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(seed: [.mailAppPassword: "app-pw"]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier()
        )
        XCTAssertFalse(appState.canCreateFollowUp)

        let accepted = await appState.handleWatchedTranscript(try TranscriptIngest.fromPaste("Marcus: recap."))

        XCTAssertFalse(accepted)
        XCTAssertNotNil(appState.transcriptFolderError)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testWatchedTranscriptReturnsFalseWhenPendingDraftCannotPersist() async throws {
        let (appState, _, _, persistence) = makeAppState()
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        let accepted = await appState.handleWatchedTranscript(
            try TranscriptIngest.fromPaste("Marcus: recap.")
        )

        XCTAssertFalse(accepted)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.transcriptFolderError)
    }

    func testMailConnectionCatchesUpRejectedWatchedTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let secrets = InMemorySecretStore(seed: [
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            transcriptWatchedFolderEnabled: true,
            transcriptWatchedFolderPath: dir.path
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "Follow up."))),
            notifier: FakeDraftNotifier()
        )
        appState.startTranscriptFolderWatchingIfEnabled()
        guard let source = appState.transcriptFolderSource else {
            return XCTFail("Expected transcript folder source")
        }

        try "Marcus: recap.".write(to: dir.appendingPathComponent("call.txt"), atomically: true, encoding: .utf8)
        await source.scanForNewTranscripts()
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.transcriptFolderError)

        await appState.testConnection(with: MailAccountCredentials(
            email: "me@gmail.com",
            appPassword: "app-pw",
            host: "imap.gmail.com",
            port: 993
        ))

        for _ in 0..<100 where appState.pendingDrafts.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(appState.pendingDrafts.count, 1)
    }

    func testInactiveTranscriptFolderSourceIsRebuiltForSameFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inactive-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let appState = AppState(persistence: AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            transcriptWatchedFolderEnabled: true,
            transcriptWatchedFolderPath: dir.path
        )))
        appState.startTranscriptFolderWatchingIfEnabled()
        let failedSource = appState.transcriptFolderSource
        XCTAssertFalse(failedSource?.isActive ?? true)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        appState.startTranscriptFolderWatchingIfEnabled()

        XCTAssertTrue(appState.transcriptFolderSource?.isActive ?? false)
        XCTAssertFalse(appState.transcriptFolderSource === failedSource)
    }

    func testFollowUpSubjectFallbacks() {
        XCTAssertEqual(AppState.followUpSubject("  Custom  ", suggestedTitle: "T"), "Custom")
        XCTAssertEqual(AppState.followUpSubject(nil, suggestedTitle: "Weekly Sync"), "Follow-up: Weekly Sync")
        XCTAssertEqual(AppState.followUpSubject(nil, suggestedTitle: nil), "Post-call follow-up")
    }
}
