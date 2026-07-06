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

    /// Fetches the text body of the message identified by `uid` in `mailbox`.
    ///
    /// Uses `BODY.PEEK[TEXT]` so reading the body does not set the `\Seen`
    /// flag. Returns the raw text body as sent by the server (still MIME-
    /// structured for multipart messages); use `MailBodyText.plainText(from:)`
    /// to reduce it to human-readable text. The raw bytes are preserved so MIME
    /// part charsets can be applied before decoding.
    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32
    ) async throws -> Data
}
