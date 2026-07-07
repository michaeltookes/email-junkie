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
        draftError = nil
        generatedDraft = nil

        guard let key = ((try? secrets.value(for: llmProviderKind.apiKeySecret)) ?? nil), !key.isEmpty,
              isLLMConnected else {
            draftError = "Connect an AI provider first (Test Connection above)."
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            draftError = "Connect an email account first."
            return
        }

        isGeneratingDraft = true
        defer { isGeneratingDraft = false }

        do {
            let data = try await mailProvider.fetchBodyText(
                credentials,
                mailbox: mailbox,
                uid: message.id,
                expectedUIDValidity: message.uidValidity
            )
            let context = ReplyContext(
                senderName: message.from?.name,
                senderEmail: message.from?.email,
                subject: message.subject,
                body: MailBodyText.plainText(from: data)
            )
            let body = try await makeReplyBody(context: context, key: key)
            generatedDraft = Draft(
                id: message.id,
                sourceUIDValidity: message.uidValidity,
                sourceSubject: message.subject,
                sourceFrom: message.from,
                replySubject: Self.replySubject(for: message.subject),
                body: body,
                model: resolvedLLMModel,
                generatedAt: Date()
            )
        } catch {
            draftError = Self.draftMessage(for: error)
        }
    }

    // MARK: - Helpers

    private func makeReplyBody(context: ReplyContext, key: String) async throws -> String {
        let provider = llmProviderKind
        let model = resolvedLLMModel
        let profile = voiceProfile
        return try await DraftGenerator().makeDraft(
            replyingTo: context,
            voiceProfile: profile,
            model: model
        ) { [llm] request in
            try await llm.complete(request, provider: provider, apiKey: key)
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
