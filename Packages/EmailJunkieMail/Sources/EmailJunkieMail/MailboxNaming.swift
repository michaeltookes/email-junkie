import Foundation

/// The provider-specific names of a mailbox's special folders (Sent, Drafts,
/// All-Mail, Junk).
///
/// IMAP has no universal names for these: Gmail uses `[Gmail]/Sent Mail`,
/// Yahoo/AT&T use `Sent` / `Draft` / `Bulk Mail`, while iCloud uses
/// `Sent Messages` for sent mail. Most non-Gmail providers have no all-mail
/// folder at all. So the correct folder is resolved per account (from the IMAP
/// host) rather than hardcoded to Gmail. A future enhancement can discover these
/// from the server via IMAP `LIST` SPECIAL-USE attributes (RFC 6154).
public struct MailboxNaming: Equatable, Sendable {
    public var sent: String
    public var drafts: String
    /// The "all mail" / archive-of-everything folder, or `nil` when the provider
    /// has none (Yahoo/AT&T). Callers fall back to INBOX when this is `nil`.
    public var allMail: String?
    /// The spam/junk folder, when known.
    public var junk: String?

    public init(sent: String, drafts: String, allMail: String?, junk: String? = nil) {
        self.sent = sent
        self.drafts = drafts
        self.allMail = allMail
        self.junk = junk
    }

    /// Gmail's special-folder layout (the historical default).
    public static let gmail = MailboxNaming(
        sent: "[Gmail]/Sent Mail",
        drafts: "[Gmail]/Drafts",
        allMail: "[Gmail]/All Mail",
        junk: "[Gmail]/Spam"
    )

    /// Yahoo-family layout, which also covers AT&T (`att.net`), AOL, and other
    /// Yahoo-backed hosts. These providers have no all-mail folder.
    public static let yahoo = MailboxNaming(
        sent: "Sent",
        drafts: "Draft",
        allMail: nil,
        junk: "Bulk Mail"
    )

    /// iCloud/Me/Mac layout. iCloud uses a non-generic Sent folder name and has
    /// no all-mail folder.
    public static let icloud = MailboxNaming(
        sent: "Sent Messages",
        drafts: "Drafts",
        allMail: nil,
        junk: "Junk"
    )

    /// A conservative layout for unrecognized IMAP providers.
    public static let generic = MailboxNaming(
        sent: "Sent",
        drafts: "Drafts",
        allMail: nil,
        junk: "Junk"
    )

    /// Whether this account exposes an all-mail folder (drives whether an
    /// "All Mail" search target is offered).
    public var supportsAllMail: Bool { allMail != nil }

    /// Resolves the special-folder layout for an IMAP host, falling back to the
    /// generic layout for unrecognized hosts.
    public static func forHost(_ host: String) -> MailboxNaming {
        let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("gmail") || lowered.contains("googlemail") {
            return .gmail
        }
        if yahooBackedFragments.contains(where: lowered.contains) {
            return .yahoo
        }
        if icloudHostSuffixes.contains(where: lowered.hasSuffix) {
            return .icloud
        }
        return .generic
    }

    /// Host substrings that identify a Yahoo-backed provider.
    private static let yahooBackedFragments = [
        "yahoo", "att.net", "mail.att", "aol", "ymail", "rocketmail",
        "sbcglobal", "bellsouth"
    ]

    /// Host suffixes that identify an iCloud-backed provider.
    private static let icloudHostSuffixes = [
        "mail.me.com", "mail.icloud.com"
    ]
}
