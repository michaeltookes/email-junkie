import EmailJunkieMail
import Foundation

/// Mail/Keychain error-message mapping for `AppState`. Kept in a separate file
/// so `AppState` stays within the file/type length limits.
extension AppState {

    /// Maps an error to a concise, user-facing message.
    static func message(for error: Error) -> String {
        switch error {
        case MailError.incompleteCredentials:
            return "Enter your email address and app password first."
        case MailError.authenticationFailed(let detail):
            return "Sign-in failed — check your email and app password. (\(detail))"
        case MailError.connectionFailed(let detail):
            return "Couldn't reach the mail server. (\(detail))"
        case MailError.commandFailed(let detail):
            return "The mail server rejected a request. (\(detail))"
        case MailError.resultTooLarge:
            return "Too many messages matched to list at once. Narrow your search "
                + "(a specific sender, keyword, or date) and try again."
        case KeychainError.unexpectedStatus(let status):
            return "Keychain returned status \(status)."
        case KeychainError.dataEncodingFailed:
            return "Keychain could not encode the app password."
        default:
            return error.localizedDescription
        }
    }

    static func keychainMessage(action: String, error: Error) -> String {
        "Couldn't \(action) the app password in Keychain. \(message(for: error))"
    }

    static func legacyOAuthCleanupMessage(error: Error) -> String {
        "Couldn't remove the legacy Gmail OAuth credentials from Keychain. \(message(for: error))"
    }

    static func settingsMessage(action: String, error: Error) -> String {
        "Couldn't \(action) mailbox settings. \(message(for: error))"
    }
}
