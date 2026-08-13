import EmailJunkieMail
import Foundation

/// User-facing error copy for draft dispatch, and the dispatch error type. Split
/// out of `AppState+Draft` to keep that file within length limits.
extension AppState {

    /// Maps a draft-generation or dispatch error to a short, user-facing message.
    static func draftMessage(for error: Error) -> String {
        switch error {
        case let error as DraftDispatchError:
            return draftDispatchMessage(for: error)
        case DraftError.emptyDraft:
            return "The model returned an empty reply. Try again."
        case DraftError.llmUnavailable:
            return "Connect an AI provider first (Test Connection in Settings)."
        case DraftError.unsupportedSourceMailbox:
            return "Draft replies are only available for incoming mail."
        case DraftError.needsUserInput:
            return "This draft needs your input before it can be sent — add the missing details or write the reply yourself."
        case DraftError.sourceMessageUnavailable:
            return "No current message was found to regenerate from. Send anyway or discard this draft."
        case is LLMError:
            return llmMessage(for: error)
        default:
            return message(for: error)
        }
    }

    /// Builds the RFC 5322 message for a draft. An authored follow-up (item 51)
    /// has no source message, so it sends to the user-supplied recipients with a
    /// verbatim subject and no reply threading; a reply derives its recipient and
    /// `In-Reply-To`/`References` from the source message.
    static func outgoingMessage(for draft: Draft, from: String, date: Date, messageID: String) -> OutgoingMessage {
        if let recipients = draft.authoredRecipients {
            return OutgoingMessage(
                from: from,
                to: recipients.map(\.email),
                subject: draft.replySubject,
                body: draft.body,
                date: date,
                messageID: messageID,
                inReplyTo: nil,
                references: []
            )
        }
        return OutgoingMessage(
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

    /// Whether a draft was generated under the currently connected account.
    func draftMatchesCurrentAccount(_ draft: Draft, credentials: MailAccountCredentials) -> Bool {
        guard let sourceAccount = draft.sourceAccountEmail else { return false }
        return normalizedEmail(sourceAccount) == normalizedEmail(credentials.email)
    }

    func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func draftDispatchMessage(for error: DraftDispatchError) -> String {
        switch error {
        case .missingCredentials:
            return "Connect an email account first."
        case .accountMismatch:
            return "This draft was generated for a different email account."
        case .accountChanged:
            return "The email account changed before this action finished. Try again with the current account."
        case .noRecipient:
            return "This draft has no recipient address to send to."
        case .staleThread(let reason):
            return "\(reason.headline). \(reason.detail)"
        }
    }
}

/// Errors dispatching an approved draft to send/save.
enum DraftDispatchError: Error, Equatable {
    /// No connected mail account is available for dispatch.
    case missingCredentials
    /// The draft was generated under a different mail account.
    case accountMismatch
    /// The connected account changed while an async freshness or regeneration
    /// operation was in flight.
    case accountChanged
    /// The draft has no resolvable recipient address.
    case noRecipient
    /// The source thread changed since the draft was generated (item 12); carries
    /// why so the UI can warn precisely before a "send anyway" override.
    case staleThread(StaleThreadReason)
}
