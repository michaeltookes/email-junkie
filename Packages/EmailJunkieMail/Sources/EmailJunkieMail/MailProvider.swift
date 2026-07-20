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

    /// Searches `mailbox` server-side (IMAP `UID SEARCH`) for messages matching
    /// `criteria`, returning one page of envelope-level results (newest first)
    /// plus the total match count. `offset`/`limit` page through the full match
    /// set so large mailboxes never download in full. Throws `MailError` on
    /// failure.
    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult

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

    /// Default: searching is unsupported. `IMAPMailProvider` overrides this so
    /// other conformers (test doubles, non-IMAP backends) inherit a clear
    /// failure rather than a compile-time requirement.
    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        throw MailError.commandFailed("This provider does not support searching mail.")
    }
}

/// A read/unread filter for a mailbox search.
public enum MailReadState: Sendable, Equatable, Hashable {
    /// No read-state constraint.
    case any
    /// Only unread messages (IMAP `UNSEEN`).
    case unreadOnly
    /// Only read messages (IMAP `SEEN`).
    case readOnly
}

/// Criteria for a server-side mailbox search. Every set field is combined with
/// `AND`; leaving them all unset matches every message (newest first). Blank
/// text fields are ignored, so an empty search box behaves like "recent mail".
public struct MailSearchCriteria: Sendable, Equatable {
    /// Free-text keyword matched against the whole message (IMAP `TEXT`).
    public var text: String?
    /// Matched against the `From` header (IMAP `FROM`).
    public var from: String?
    /// Matched against the `Subject` header (IMAP `SUBJECT`).
    public var subject: String?
    /// Only messages on/after this calendar day (IMAP `SINCE`).
    public var since: Date?
    /// Only messages before this calendar day (IMAP `BEFORE`).
    public var before: Date?
    /// Read/unread constraint.
    public var readState: MailReadState
    /// Only flagged/starred messages (IMAP `FLAGGED`).
    public var flaggedOnly: Bool
    /// Optional high-water UID, used to keep paged result sets stable when newer
    /// matching messages arrive after the first page was loaded.
    public var maximumUID: UInt32?

    public init(
        text: String? = nil,
        from: String? = nil,
        subject: String? = nil,
        since: Date? = nil,
        before: Date? = nil,
        readState: MailReadState = .any,
        flaggedOnly: Bool = false,
        maximumUID: UInt32? = nil
    ) {
        self.text = text
        self.from = from
        self.subject = subject
        self.since = since
        self.before = before
        self.readState = readState
        self.flaggedOnly = flaggedOnly
        self.maximumUID = maximumUID
    }

    /// True when no filter is set — the search reduces to "all mail, newest
    /// first". Blank/whitespace-only text fields do not count as a filter.
    public var isEmpty: Bool {
        Self.isBlank(text) && Self.isBlank(from) && Self.isBlank(subject)
            && since == nil && before == nil && readState == .any && !flaggedOnly && maximumUID == nil
    }

    private static func isBlank(_ value: String?) -> Bool {
        (value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
}

/// One page of mailbox-search results.
public struct MailSearchResult: Sendable, Equatable {
    /// This page of messages, newest first.
    public var messages: [MailMessage]
    /// Total number of messages the search matched across all pages.
    public var totalMatches: Int
    /// The offset into the full match set this page started at.
    public var offset: Int
    /// Whether more results exist beyond this page.
    public var hasMore: Bool

    public init(messages: [MailMessage], totalMatches: Int, offset: Int, hasMore: Bool) {
        self.messages = messages
        self.totalMatches = totalMatches
        self.offset = offset
        self.hasMore = hasMore
    }

    /// An empty result (no matches), used when a search returns nothing or the
    /// requested page is beyond the match set.
    public static func empty(offset: Int) -> MailSearchResult {
        MailSearchResult(messages: [], totalMatches: 0, offset: offset, hasMore: false)
    }
}
