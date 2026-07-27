import Foundation

/// A recognized email provider, classified from an address's domain. Drives both
/// the IMAP-host suggestion (item 41) and the connect-screen credential guidance
/// (item 43), so the two share one source of truth for "which provider is this".
enum EmailProviderKind: Equatable, CaseIterable {
    case gmail
    case att
    case yahoo
    case aol
    case icloud

    /// Classifies an email address by domain, or `nil` when unrecognized.
    static func forEmail(_ email: String) -> EmailProviderKind? {
        guard let domain = Self.domain(of: email) else { return nil }
        return domainMap[domain]
    }

    /// The IMAP host for this provider (its SMTP host is derived from it).
    var imapHost: String {
        switch self {
        case .gmail: return "imap.gmail.com"
        case .att: return "imap.mail.att.net"
        case .yahoo: return "imap.mail.yahoo.com"
        case .aol: return "imap.aol.com"
        case .icloud: return "imap.mail.me.com"
        }
    }

    /// Every recognized provider host, treated as a "default" the domain-derived
    /// suggestion may replace (a hand-entered custom host is never one of these).
    static var allHosts: Set<String> {
        Set(allCases.map(\.imapHost))
    }

    /// The lowercased domain of an email address, or `nil` if malformed.
    private static func domain(of email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let domain = String(trimmed[trimmed.index(after: at)...])
        return domain.isEmpty ? nil : domain
    }

    /// Domains kept identical to item 41's original host map, so host suggestion
    /// behavior is unchanged; guidance is layered on top.
    private static let domainMap: [String: EmailProviderKind] = [
        "gmail.com": .gmail,
        "googlemail.com": .gmail,
        "att.net": .att,
        "sbcglobal.net": .att,
        "bellsouth.net": .att,
        "yahoo.com": .yahoo,
        "aol.com": .aol,
        "icloud.com": .icloud,
        "me.com": .icloud,
        "mac.com": .icloud
    ]
}
