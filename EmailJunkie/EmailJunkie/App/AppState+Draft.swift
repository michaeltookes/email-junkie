import EmailJunkieMail
import Foundation

/// Draft-generation actions on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// Whether a draft can be generated (mail + AI connected).
    var canGenerateDraft: Bool {
        isLLMConnected && mailCredentials.isComplete
    }

    /// Fetches a message's body and generates a reply draft in the user's voice.
    @discardableResult
    func generateDraft(for message: MailMessage, mailbox: Mailbox = .inbox) async -> Draft? {
        let requestGeneration = nextDraftGeneration()
        resetDraftPreviewForGeneration()

        guard mailbox.supportsReplyDrafting else {
            draftError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return nil
        }
        guard let llmConfiguration = currentDraftLLMConfiguration else {
            draftError = "Connect an AI provider first (Test Connection above)."
            return nil
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            draftError = "Connect an email account first."
            return nil
        }

        isGeneratingDraft = true
        defer {
            if isLatestDraftRequest(requestGeneration) {
                isGeneratingDraft = false
            }
        }

        do {
            let data = try await mailProvider.fetchBodyText(
                credentials,
                mailbox: mailbox,
                uid: message.id,
                expectedUIDValidity: message.uidValidity
            )
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else {
                return nil
            }
            let context = ReplyContext(
                senderName: message.from?.name,
                senderEmail: message.from?.email,
                subject: message.subject,
                body: MailBodyText.plainText(from: data)
            )
            let body = try await makeReplyBody(context: context, llmConfiguration: llmConfiguration)
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else {
                return nil
            }
            let draft = Self.draftPreview(
                for: message,
                body: body,
                llmConfiguration: llmConfiguration,
                credentials: credentials,
                mailbox: mailbox
            )
            generatedDraft = draft
            return draft
        } catch {
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else {
                return nil
            }
            draftError = Self.draftMessage(for: error)
            return nil
        }
    }

    /// Builds a reply draft for a watcher-selected message and appends it to the
    /// pending queue. Unlike `generateDraft`, this does not touch the Settings
    /// preview state, so an active preview and the watcher don't clobber each
    /// other. Throws on missing configuration or provider/LLM errors.
    @discardableResult
    func draftAndEnqueue(_ message: MailMessage, mailbox: Mailbox = .inbox) async throws -> Bool {
        guard mailbox.supportsReplyDrafting else {
            throw DraftError.unsupportedSourceMailbox
        }
        guard let llmConfiguration = currentDraftLLMConfiguration else {
            throw DraftError.emptyDraft
        }
        let credentials = mailCredentials
        let data = try await mailProvider.fetchBodyText(
            credentials,
            mailbox: mailbox,
            uid: message.id,
            expectedUIDValidity: message.uidValidity
        )
        guard isCurrentWatcherDraftRequest(credentials: credentials, llmConfiguration: llmConfiguration) else { return false }
        let incomingText = MailBodyText.plainText(from: data)
        let context = ReplyContext(
            senderName: message.from?.name,
            senderEmail: message.from?.email,
            subject: message.subject,
            body: incomingText
        )
        let body = try await makeReplyBody(context: context, llmConfiguration: llmConfiguration)
        guard isCurrentWatcherDraftRequest(credentials: credentials, llmConfiguration: llmConfiguration) else { return false }
        let draft = Draft(
            id: message.id,
            sourceUIDValidity: message.uidValidity,
            sourceAccountEmail: credentials.email,
            sourceMailbox: mailbox.imapName,
            sourceSubject: message.subject,
            sourceFrom: message.from,
            sourceReplyTo: message.replyTo,
            sourceMessageID: message.messageID,
            incomingBody: Self.truncatedIncomingBody(incomingText),
            replySubject: Self.replySubject(for: message.subject),
            body: body,
            model: llmConfiguration.model,
            generatedAt: Date()
        )
        try enqueuePendingDraft(draft)
        return true
    }

    // MARK: - Helpers

    func nextDraftGeneration() -> Int {
        draftGeneration += 1
        return draftGeneration
    }

    func clearDraftPreview() {
        generatedDraft = nil
        draftError = nil
        draftSavedMessage = nil
        draftSentMessage = nil
    }

    func resetDraftPreviewForLLMChange() {
        _ = nextDraftGeneration()
        clearDraftPreview()
        isGeneratingDraft = false
    }

    private func resetDraftPreviewForGeneration() {
        bodyError = nil
        clearDraftPreview()
        isGeneratingDraft = false
    }

    private var currentDraftLLMConfiguration: DraftLLMConfiguration? {
        guard isLLMConnected,
              let key = ((try? secrets.value(for: llmProviderKind.apiKeySecret)) ?? nil),
              !key.isEmpty else {
            return nil
        }
        return DraftLLMConfiguration(
            provider: llmProviderKind,
            model: resolvedLLMModel,
            apiKey: key
        )
    }

    private static func draftPreview(
        for message: MailMessage,
        body: String,
        llmConfiguration: DraftLLMConfiguration,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) -> Draft {
        Draft(
            id: message.id,
            sourceUIDValidity: message.uidValidity,
            sourceAccountEmail: credentials.email,
            sourceMailbox: mailbox.imapName,
            sourceSubject: message.subject,
            sourceFrom: message.from,
            sourceReplyTo: message.replyTo,
            sourceMessageID: message.messageID,
            replySubject: replySubject(for: message.subject),
            body: body,
            model: llmConfiguration.model,
            generatedAt: Date()
        )
    }

    private func isCurrentDraftRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials,
        llmConfiguration: DraftLLMConfiguration
    ) -> Bool {
        draftGeneration == requestGeneration
            && mailCredentials == credentials
            && currentDraftLLMConfiguration == llmConfiguration
    }

    private func isCurrentWatcherDraftRequest(
        credentials: MailAccountCredentials,
        llmConfiguration: DraftLLMConfiguration
    ) -> Bool {
        watchStatus == .watching
            && mailCredentials == credentials
            && currentDraftLLMConfiguration == llmConfiguration
    }

    private func enqueuePendingDraft(_ draft: Draft) throws {
        pendingDrafts.append(draft)
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
            pendingDraftCount = pendingDrafts.count
        } catch {
            pendingDrafts.removeLast()
            pendingDraftCount = pendingDrafts.count
            throw error
        }
        notifier.notify(for: draft, sendBehavior: sendBehavior)
    }

    func isLatestDraftRequest(_ requestGeneration: Int) -> Bool {
        draftGeneration == requestGeneration
    }

    private func makeReplyBody(
        context: ReplyContext,
        llmConfiguration: DraftLLMConfiguration
    ) async throws -> String {
        let profile = voiceProfile
        return try await DraftGenerator().makeDraft(
            replyingTo: context,
            voiceProfile: profile,
            model: llmConfiguration.model
        ) { [llm] request in
            try await llm.complete(
                request,
                provider: llmConfiguration.provider,
                apiKey: llmConfiguration.apiKey
            )
        }
    }

    /// Approves the current draft, dispatching on the user's send-behavior
    /// setting: send immediately over SMTP, or save a Gmail draft.
    func approveGeneratedDraft() async {
        switch sendBehavior {
        case .autoSend:
            await sendGeneratedDraft()
        case .saveAsDraft:
            await saveGeneratedDraftToDrafts()
        }
    }

    /// Dispatches a preview sheet's displayed draft without reading mutable
    /// global preview state. The sheet owns its own progress/error UI.
    func approveDraftPreview(_ draft: Draft) async throws -> String {
        let credentials = mailCredentials
        guard credentials.isComplete else {
            throw DraftDispatchError.missingCredentials
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            if generatedDraft == draft {
                generatedDraft = nil
            }
            throw DraftDispatchError.accountMismatch
        }

        switch sendBehavior {
        case .autoSend:
            try await performSend(draft, credentials: credentials)
            if generatedDraft == draft {
                generatedDraft = nil
            }
            return "Sent."
        case .saveAsDraft:
            try await performSave(draft, credentials: credentials)
            return "Saved to your Drafts."
        }
    }

    /// Sends the current generated draft immediately over SMTP.
    func sendGeneratedDraft() async {
        guard !isSendingDraft, !isSavingDraft else { return }

        draftError = nil
        draftSentMessage = nil
        draftSavedMessage = nil

        guard let draft = generatedDraft else { return }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            draftError = "Connect an email account first."
            return
        }

        isSendingDraft = true
        defer { isSendingDraft = false }

        do {
            try await performSend(draft, credentials: credentials)
            draftSentMessage = "Sent."
            generatedDraft = nil
        } catch {
            draftError = Self.draftMessage(for: error)
        }
    }

    /// Saves the current generated draft to the Drafts mailbox via IMAP APPEND.
    func saveGeneratedDraftToDrafts() async {
        guard !isSavingDraft, !isSendingDraft else { return }

        draftError = nil
        draftSavedMessage = nil

        guard let draft = generatedDraft else { return }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            draftError = "Connect an email account first."
            return
        }

        isSavingDraft = true
        defer { isSavingDraft = false }

        do {
            try await performSave(draft, credentials: credentials)
            draftSavedMessage = "Saved to your Drafts."
        } catch {
            draftError = Self.draftMessage(for: error)
        }
    }

    /// Sends `draft` over SMTP. Shared by the Settings preview and the approval
    /// queue. Throws `DraftDispatchError.noRecipient` when there is no address.
    func performSend(_ draft: Draft, credentials: MailAccountCredentials) async throws {
        let outgoing = Self.outgoingMessage(
            for: draft,
            from: credentials.email,
            date: Date(),
            messageID: Self.generateMessageID(forEmail: credentials.email)
        )
        guard !outgoing.to.isEmpty else { throw DraftDispatchError.noRecipient }
        try await mailProvider.sendMessage(
            credentials,
            rfc822: outgoing.rfc822(),
            envelope: SMTPEnvelope(sender: credentials.email, recipients: outgoing.to)
        )
    }

    /// Saves `draft` to the Drafts mailbox. Shared by the Settings preview and
    /// the approval queue.
    func performSave(_ draft: Draft, credentials: MailAccountCredentials) async throws {
        let outgoing = Self.outgoingMessage(
            for: draft,
            from: credentials.email,
            date: Date(),
            messageID: Self.generateMessageID(forEmail: credentials.email)
        )
        try await mailProvider.appendMessage(
            credentials,
            mailbox: .drafts,
            rfc822: outgoing.rfc822(),
            flags: [.draft]
        )
    }

    static func outgoingMessage(for draft: Draft, from: String, date: Date, messageID: String) -> OutgoingMessage {
        OutgoingMessage(
            from: from,
            to: [draft.sourceReplyTo?.email ?? draft.sourceFrom?.email].compactMap { $0 },
            subject: draft.replySubject,
            body: draft.body,
            date: date,
            messageID: messageID,
            inReplyTo: draft.sourceMessageID,
            references: [draft.sourceMessageID].compactMap { $0 }
        )
    }

    static func generateMessageID(forEmail email: String) -> String {
        let host = email.split(separator: "@").last.map(String.init) ?? "emailjunkie.local"
        return "<\(UUID().uuidString)@\(host)>"
    }

    static func replySubject(for subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("re:") ? trimmed : "Re: \(trimmed)"
    }

    /// Bounds the incoming body kept for the approval preview so the persisted
    /// queue stays small; the full message is re-fetchable from the server.
    static func truncatedIncomingBody(_ text: String, maxChars: Int = 4000) -> String {
        text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
    }

    static func draftMessage(for error: Error) -> String {
        switch error {
        case DraftDispatchError.missingCredentials:
            return "Connect an email account first."
        case DraftDispatchError.accountMismatch:
            return "This draft was generated for a different email account."
        case DraftError.emptyDraft:
            return "The model returned an empty reply. Try again."
        case DraftError.unsupportedSourceMailbox:
            return "Draft replies are only available for incoming mail."
        case DraftDispatchError.noRecipient:
            return "This draft has no recipient address to send to."
        case is LLMError:
            return llmMessage(for: error)
        default:
            return message(for: error)
        }
    }
}

/// Errors dispatching an approved draft to send/save.
enum DraftDispatchError: Error, Equatable {
    /// No connected mail account is available for dispatch.
    case missingCredentials
    /// The draft was generated under a different mail account.
    case accountMismatch
    /// The draft has no resolvable recipient address.
    case noRecipient
}

private struct DraftLLMConfiguration: Equatable {
    let provider: LLMProviderKind
    let model: String
    let apiKey: String
}
