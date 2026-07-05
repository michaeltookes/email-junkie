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
    public var from: MailAddress?
    public var subject: String
    public var date: String

    public init(id: UInt32, from: MailAddress?, subject: String, date: String) {
        self.id = id
        self.from = from
        self.subject = subject
        self.date = date
    }
}

/// A mailbox to fetch from.
public enum Mailbox: Sendable, Equatable {
    case inbox
    case sent
    /// A provider-specific mailbox path (e.g. a custom IMAP folder).
    case named(String)

    /// The IMAP mailbox name. Sent defaults to Gmail's path.
    public var imapName: String {
        switch self {
        case .inbox: return "INBOX"
        case .sent: return "[Gmail]/Sent Mail"
        case .named(let name): return name
        }
    }
}
