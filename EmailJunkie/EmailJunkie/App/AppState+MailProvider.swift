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
        EmailProviderKind.forEmail(email)?.imapHost
    }

    /// Auto-fills the IMAP host from the email domain when the user hasn't set a
    /// custom one — i.e. the host is empty or still a recognized provider
    /// default. If the domain is unrecognized, stale provider defaults are
    /// cleared so credential guidance does not infer Gmail/AT&T/etc. from an
    /// untouched or previous-account host. A hand-entered custom host is never
    /// overwritten.
    func applySuggestedHostIfDefault() {
        let current = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isReplaceable = current.isEmpty || EmailProviderKind.allHosts.contains(current)

        guard let suggestion = Self.suggestedIMAPHost(forEmail: mailEmail) else {
            if isReplaceable, !current.isEmpty {
                mailHost = ""
            }
            return
        }

        if isReplaceable, current != suggestion {
            mailHost = suggestion
        }
    }
}
