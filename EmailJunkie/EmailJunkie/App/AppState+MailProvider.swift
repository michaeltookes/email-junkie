import EmailJunkieMail
import Foundation

/// Provider-awareness helpers on `AppState`: special-folder capability for the
/// connected account and IMAP-host suggestions from an email domain, so
/// non-Gmail users (Yahoo/AT&T) don't hit Gmail-only assumptions.
extension AppState {

    /// Host fallback for provider guidance. Only hosts the user typed in
    /// Advanced count; loaded defaults and auto-suggestions can be stale.
    var credentialGuidanceHostFallback: String? {
        guard mailHostWasExplicitlyEditedForCurrentAddress else { return nil }
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
    }

    /// Routes Advanced host-field edits through explicit tracking, so a
    /// provider host typed for a custom domain is not treated as a stale default.
    func updateMailHostFromUser(_ host: String) {
        mailHost = host
        mailHostWasExplicitlyEditedForCurrentAddress =
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isMailHostReplaceableBySuggestion(_ normalizedHost: String) -> Bool {
        normalizedHost.isEmpty
            || (!mailHostWasExplicitlyEditedForCurrentAddress
                && EmailProviderKind.allHosts.contains(normalizedHost))
    }

    private func markMailHostManagedByApp() {
        mailHostWasExplicitlyEditedForCurrentAddress = false
    }

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
    /// custom one — i.e. the host is empty or still an app-managed provider
    /// default. If the domain is unrecognized, stale provider defaults are
    /// cleared so credential guidance does not infer Gmail/AT&T/etc. from an
    /// untouched or previous-account host. A host typed in Advanced is never
    /// overwritten, even when it matches a known provider.
    func applySuggestedHostIfDefault() {
        let current = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isReplaceable = isMailHostReplaceableBySuggestion(current)

        guard let suggestion = Self.suggestedIMAPHost(forEmail: mailEmail) else {
            if isReplaceable, !current.isEmpty {
                mailHost = ""
                markMailHostManagedByApp()
            }
            return
        }

        if isReplaceable, current != suggestion {
            mailHost = suggestion
            markMailHostManagedByApp()
        }
    }
}
