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
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data

    /// Appends a full RFC 822 message to `mailbox` via IMAP `APPEND`, tagging it
    /// with the given flags (e.g. `\Draft`). Used to save a reply as a draft
    /// without sending it. Throws `MailError` on failure.
    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws

    /// Submits a full RFC 822 message for delivery over SMTP (implicit TLS),
    /// authenticating with the app password. `envelope` carries the SMTP-level
    /// sender and recipients (`MAIL FROM` / `RCPT TO`), which need not match the
    /// message's display headers. Throws `MailError` on failure.
    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws
}

/// The SMTP-level addressing for a message: the return-path sender and the
/// recipients the server should deliver to. Distinct from the display `From:`/
/// `To:` headers in the message body.
public struct SMTPEnvelope: Sendable, Equatable {
    /// The `MAIL FROM` return-path address (bare, no display name).
    public var sender: String
    /// The `RCPT TO` recipient addresses (bare, no display names).
    public var recipients: [String]

    public init(sender: String, recipients: [String]) {
        self.sender = sender
        self.recipients = recipients
    }
}

/// IMAP message flags supported when appending.
public enum MailFlag: Sendable, Equatable {
    case draft
    case seen
}

public extension MailProvider {
    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32
    ) async throws -> Data {
        try await fetchBodyText(
            credentials,
            mailbox: mailbox,
            uid: uid,
            expectedUIDValidity: nil
        )
    }

    /// Default: sending is unsupported. Providers that can submit mail (e.g.
    /// `IMAPMailProvider` via SMTP) override this; other conformers inherit a
    /// clear failure rather than a compile-time requirement.
    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws {
        throw MailError.commandFailed("This provider does not support sending mail.")
    }
}
