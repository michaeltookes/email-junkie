import Foundation

/// A parsed email address (from an IMAP envelope).
public struct MailAddress: Equatable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }
}

/// A message summary fetched from a mailbox. Envelope-level for now; the body is
/// added in a later slice.
public struct MailMessage: Equatable, Sendable, Identifiable {
    /// The IMAP UID — stable within a mailbox.
    public var id: UInt32
    /// The mailbox UIDVALIDITY captured with this UID, when the server provides it.
    public var uidValidity: UInt32?
    public var from: MailAddress?
    public var subject: String
    public var date: String
    /// The RFC 5322 `Message-ID` (with angle brackets), when the server provides
    /// it. Used to thread replies via `In-Reply-To`/`References`.
    public var messageID: String?

    public init(
        id: UInt32,
        uidValidity: UInt32? = nil,
        from: MailAddress?,
        subject: String,
        date: String,
        messageID: String? = nil
    ) {
        self.id = id
        self.uidValidity = uidValidity
        self.from = from
        self.subject = subject
        self.date = date
        self.messageID = messageID
    }
}

/// A mailbox to fetch from.
public enum Mailbox: Sendable, Equatable {
    case inbox
    case sent
    case drafts
    /// A provider-specific mailbox path (e.g. a custom IMAP folder).
    case named(String)

    /// The IMAP mailbox name. Sent/Drafts default to Gmail's paths.
    public var imapName: String {
        switch self {
        case .inbox: return "INBOX"
        case .sent: return "[Gmail]/Sent Mail"
        case .drafts: return "[Gmail]/Drafts"
        case .named(let name): return name
        }
    }
}
