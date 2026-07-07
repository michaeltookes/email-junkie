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
    func generateDraft(for message: MailMessage, mailbox: Mailbox = .inbox) async {
        let requestGeneration = nextDraftGeneration()
        bodyError = nil
        draftError = nil
        generatedDraft = nil
        isGeneratingDraft = false

        guard let llmConfiguration = currentDraftLLMConfiguration else {
            draftError = "Connect an AI provider first (Test Connection above)."
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            draftError = "Connect an email account first."
            return
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
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else { return }
            let context = ReplyContext(
                senderName: message.from?.name,
                senderEmail: message.from?.email,
                subject: message.subject,
                body: MailBodyText.plainText(from: data)
            )
            let body = try await makeReplyBody(context: context, llmConfiguration: llmConfiguration)
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else { return }
            generatedDraft = Draft(
                id: message.id,
                sourceUIDValidity: message.uidValidity,
                sourceSubject: message.subject,
                sourceFrom: message.from,
                replySubject: Self.replySubject(for: message.subject),
                body: body,
                model: llmConfiguration.model,
                generatedAt: Date()
            )
        } catch {
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else { return }
            draftError = Self.draftMessage(for: error)
        }
    }

    // MARK: - Helpers

    func nextDraftGeneration() -> Int {
        draftGeneration += 1
        return draftGeneration
    }

    func clearDraftPreview() {
        generatedDraft = nil
        draftError = nil
    }

    func resetDraftPreviewForLLMChange() {
        _ = nextDraftGeneration()
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

    private func isCurrentDraftRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials,
        llmConfiguration: DraftLLMConfiguration
    ) -> Bool {
        draftGeneration == requestGeneration
            && mailCredentials == credentials
            && currentDraftLLMConfiguration == llmConfiguration
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

    static func replySubject(for subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("re:") ? trimmed : "Re: \(trimmed)"
    }

    static func draftMessage(for error: Error) -> String {
        switch error {
        case DraftError.emptyDraft:
            return "The model returned an empty reply. Try again."
        case is LLMError:
            return llmMessage(for: error)
        default:
            return message(for: error)
        }
    }
}

private struct DraftLLMConfiguration: Equatable {
    let provider: LLMProviderKind
    let model: String
    let apiKey: String
}
