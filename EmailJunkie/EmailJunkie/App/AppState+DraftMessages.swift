import EmailJunkieMail
import Foundation

/// User-facing error copy for draft dispatch, and the dispatch error type. Split
/// out of `AppState+Draft` to keep that file within length limits.
extension AppState {

    /// Maps a draft-generation or dispatch error to a short, user-facing message.
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
        case DraftError.needsUserInput:
            return "This draft needs your input before it can be sent — add the missing details or write the reply yourself."
        case DraftError.sourceMessageUnavailable:
            return "No current message was found to regenerate from. Send anyway or discard this draft."
        case DraftDispatchError.noRecipient:
            return "This draft has no recipient address to send to."
        case DraftDispatchError.staleThread(let reason):
            return "\(reason.headline). \(reason.detail)"
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
    /// The source thread changed since the draft was generated (item 12); carries
    /// why so the UI can warn precisely before a "send anyway" override.
    case staleThread(StaleThreadReason)
}
