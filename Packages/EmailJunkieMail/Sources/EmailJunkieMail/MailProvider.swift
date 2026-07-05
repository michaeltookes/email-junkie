import Foundation

/// Errors surfaced by a `MailProvider`.
public enum MailError: Error, Equatable, Sendable {
    /// Required credential fields are missing.
    case incompleteCredentials
    /// The connection (TCP/TLS) could not be established.
    case connectionFailed(String)
    /// The server rejected the credentials.
    case authenticationFailed(String)
    /// An IMAP command (e.g. SELECT/FETCH) failed.
    case commandFailed(String)
}

/// A mailbox backend. Exposes a connection check plus recent-message fetch;
/// send is layered on next.
public protocol MailProvider: Sendable {
    /// Connects, authenticates, and disconnects. Throws `MailError` on failure.
    func verifyConnection(_ credentials: MailAccountCredentials) async throws

    /// Fetches up to `limit` of the most recent messages from `mailbox`
    /// (newest first). Envelope-level for now.
    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage]
}

