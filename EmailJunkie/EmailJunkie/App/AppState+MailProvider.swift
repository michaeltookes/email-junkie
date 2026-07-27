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

    var mailHostWasExplicitlyEditedForCurrentAddress: Bool {
        guard let editedEmail = mailHostExplicitlyEditedEmail,
              let currentEmail = Self.normalizedEmailForHostTracking(mailEmail) else {
            return false
        }
        return editedEmail == currentEmail
    }

    /// Routes email-field edits through host tracking before applying provider
    /// suggestions. An explicit host stays attached while the same custom
    /// domain address is being edited, but recognized or unrelated domains can
    /// supersede a provider host from the previous address.
    func updateMailEmailFromUser(_ email: String) {
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackedDomain = mailHostExplicitlyEditedEmail.flatMap(Self.normalizedEmailDomainForHostTracking)
        let hasHostAssociatedWithTrackedEmail = trackedDomain != nil && !host.isEmpty
        let hasHostEnteredBeforeEmail = mailHostExplicitlyEditedBeforeEmail && !host.isEmpty

        mailEmail = email

        if hasHostEnteredBeforeEmail {
            if Self.suggestedIMAPHost(forEmail: email) != nil {
                markMailHostManagedByApp()
            } else if Self.normalizedEmailDomainForHostTracking(email) != nil {
                mailHostExplicitlyEditedBeforeEmail = false
                mailHostExplicitlyEditedEmail = Self.normalizedEmailForHostTracking(email)
            } else {
                return
            }
        } else if hasHostAssociatedWithTrackedEmail {
            guard let currentDomain = Self.normalizedEmailDomainForHostTracking(email) else {
                return
            }

            if trackedDomain == currentDomain {
                mailHostExplicitlyEditedEmail = Self.normalizedEmailForHostTracking(email)
                return
            }

            mailHost = ""
            markMailHostManagedByApp()
        }

        applySuggestedHostIfDefault()
    }

    /// Routes Advanced host-field edits through explicit tracking, so a
    /// provider host typed for a custom domain is not treated as a stale default.
    func updateMailHostFromUser(_ host: String) {
        mailHost = host
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = Self.normalizedEmailForHostTracking(mailEmail)
        let hasCompletedEmailDomain = Self.normalizedEmailDomainForHostTracking(mailEmail) != nil
        mailHostExplicitlyEditedEmail = normalizedHost.isEmpty || !hasCompletedEmailDomain ? nil : normalizedEmail
        mailHostExplicitlyEditedBeforeEmail = !normalizedHost.isEmpty && !hasCompletedEmailDomain
    }

    private func isMailHostReplaceableBySuggestion(
        _ normalizedHost: String,
        suggestedHost: String?
    ) -> Bool {
        if normalizedHost.isEmpty { return true }
        guard EmailProviderKind.allHosts.contains(normalizedHost) else { return false }
        if let suggestedHost, normalizedHost != suggestedHost { return true }
        return !mailHostWasExplicitlyEditedForCurrentAddress
    }

    private func markMailHostManagedByApp() {
        mailHostExplicitlyEditedEmail = nil
        mailHostExplicitlyEditedBeforeEmail = false
    }

    func restoreMailHostGuidanceFromSettings(_ settings: Settings) {
        if !mailHostWasExplicitlyEditedForCurrentAddress {
            mailHostExplicitlyEditedEmail = nil
        }

        restorePendingMailHostGuidanceIfPossible()

        if shouldMigrateLegacyMailHostGuidance(from: settings) {
            mailHostExplicitlyEditedEmail = Self.normalizedEmailForHostTracking(mailEmail)
        }

        if isAccountConnected {
            markMailHostVerifiedForGuidance()
        } else if Self.normalizedEmailForHostTracking(mailEmail) != nil,
                  !mailHostExplicitlyEditedBeforeEmail {
            applySuggestedHostIfDefault()
        }
    }

    func markMailHostVerifiedForGuidance() {
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let guidanceEmail = Self.normalizedEmailForHostTracking(mailEmail),
              !host.isEmpty else {
            mailHostExplicitlyEditedEmail = nil
            mailHostExplicitlyEditedBeforeEmail = false
            return
        }

        if let suggestedHost = Self.suggestedIMAPHost(forEmail: mailEmail),
           host == suggestedHost {
            mailHostExplicitlyEditedEmail = nil
            mailHostExplicitlyEditedBeforeEmail = false
            return
        }

        mailHostExplicitlyEditedEmail = guidanceEmail
        mailHostExplicitlyEditedBeforeEmail = false
    }

    private func restorePendingMailHostGuidanceIfPossible() {
        guard mailHostExplicitlyEditedBeforeEmail else { return }

        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            mailHostExplicitlyEditedBeforeEmail = false
            return
        }

        if Self.suggestedIMAPHost(forEmail: mailEmail) != nil {
            markMailHostManagedByApp()
        } else if Self.normalizedEmailDomainForHostTracking(mailEmail) != nil {
            mailHostExplicitlyEditedBeforeEmail = false
            mailHostExplicitlyEditedEmail = Self.normalizedEmailForHostTracking(mailEmail)
        }
    }

    private func shouldMigrateLegacyMailHostGuidance(from settings: Settings) -> Bool {
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard settings.schemaVersion < Settings.mailHostGuidanceSchemaVersion,
              settings.mailHostGuidanceEmail == nil,
              EmailProviderKind.forEmail(mailEmail) == nil,
              Self.normalizedEmailDomainForHostTracking(mailEmail) != nil,
              !host.isEmpty else {
            return false
        }

        return host != Settings.default.mailHost || settings.onboardingCompleted
    }

    private static func normalizedEmailForHostTracking(_ email: String) -> String? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedEmailDomainForHostTracking(_ email: String) -> String? {
        guard let normalizedEmail = normalizedEmailForHostTracking(email),
              let separator = normalizedEmail.lastIndex(of: "@") else {
            return nil
        }
        let domain = normalizedEmail[normalizedEmail.index(after: separator)...]
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty }),
              let topLevelDomain = labels.last,
              topLevelDomain.count >= 2 else {
            return nil
        }
        return String(domain)
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
    /// untouched or previous-account host. A host typed in Advanced is preserved
    /// for custom domains, but a recognized address can replace a mismatched
    /// provider host from the previous address.
    func applySuggestedHostIfDefault() {
        let current = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let suggestion = Self.suggestedIMAPHost(forEmail: mailEmail) else {
            if isMailHostReplaceableBySuggestion(current, suggestedHost: nil), !current.isEmpty {
                mailHost = ""
                markMailHostManagedByApp()
            }
            return
        }

        if isMailHostReplaceableBySuggestion(current, suggestedHost: suggestion), current != suggestion {
            mailHost = suggestion
            markMailHostManagedByApp()
        }
    }
}
