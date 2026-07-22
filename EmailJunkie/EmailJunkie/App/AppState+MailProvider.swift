import EmailJunkieMail
import Foundation

/// Provider-awareness helpers on `AppState`: special-folder capability for the
/// connected account and IMAP-host suggestions from an email domain, so
/// non-Gmail users (Yahoo/AT&T) don't hit Gmail-only assumptions.
extension AppState {

    /// The special-folder layout for the currently-entered IMAP host.
    var connectedMailboxNaming: MailboxNaming { MailboxNaming.forHost(mailHost) }

    /// Whether the connected provider exposes an all-mail folder. Drives whether
    /// the browser offers an "All Mail" target (Yahoo/AT&T have none).
    var supportsAllMailFolder: Bool { connectedMailboxNaming.supportsAllMail }

    /// Suggests an IMAP host from an email address's domain, so users don't have
    /// to know their provider's server name. Returns nil for unrecognized or
    /// malformed domains. Limited to providers that work over our IMAP +
    /// app-password path with a correctly-derived SMTP host.
    static func suggestedIMAPHost(forEmail email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let domain = String(trimmed[trimmed.index(after: at)...])
        return imapHostByDomain[domain]
    }

    /// Auto-fills the IMAP host from the email domain when the user hasn't set a
    /// custom one — i.e. the host is empty or still a recognized provider
    /// default. A hand-entered custom host is never overwritten.
    func applySuggestedHostIfDefault() {
        guard let suggestion = Self.suggestedIMAPHost(forEmail: mailEmail) else { return }
        let current = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isReplaceable = current.isEmpty || Self.knownProviderHosts.contains(current)
        if isReplaceable, current != suggestion {
            mailHost = suggestion
        }
    }

    private static let imapHostByDomain: [String: String] = [
        "gmail.com": "imap.gmail.com",
        "googlemail.com": "imap.gmail.com",
        "yahoo.com": "imap.mail.yahoo.com",
        "att.net": "imap.mail.att.net",
        "sbcglobal.net": "imap.mail.att.net",
        "bellsouth.net": "imap.mail.att.net",
        "aol.com": "imap.aol.com",
        "icloud.com": "imap.mail.me.com",
        "me.com": "imap.mail.me.com",
        "mac.com": "imap.mail.me.com"
    ]

    /// The set of recognized provider hosts, treated as "default" values that may
    /// be replaced by a domain-derived suggestion.
    private static let knownProviderHosts: Set<String> =
        Set(imapHostByDomain.values.map { $0.lowercased() })
}
