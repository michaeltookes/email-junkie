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
    /// This also keeps host suggestion and credential guidance on one source of
    /// truth for provider variants.
    static func forEmail(_ email: String) -> EmailProviderKind? {
        guard let domain = Self.domain(of: email) else { return nil }
        switch domain {
        case "gmail.com", "googlemail.com":
            return .gmail
        case "att.net", "sbcglobal.net", "bellsouth.net":
            return .att
        case "yahoo.com", "ymail.com", "rocketmail.com":
            return .yahoo
        case "aol.com":
            return .aol
        case "icloud.com", "me.com", "mac.com":
            return .icloud
        default:
            return nil
        }
    }

    /// Classifies a configured IMAP host, or `nil` when it is not one of the
    /// provider defaults we know how to guide.
    static func forHost(_ host: String) -> EmailProviderKind? {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if gmailHostFragments.contains(where: normalized.contains) {
            return .gmail
        }
        if attHostFragments.contains(where: normalized.contains) {
            return .att
        }
        if yahooHostFragments.contains(where: normalized.contains) {
            return .yahoo
        }
        if aolHostFragments.contains(where: normalized.contains) {
            return .aol
        }
        if icloudHostSuffixes.contains(where: normalized.hasSuffix) {
            return .icloud
        }
        return nil
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
    static func domain(of email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let domain = String(trimmed[trimmed.index(after: at)...])
        return domain.isEmpty ? nil : domain
    }

    private static let gmailHostFragments = ["gmail", "googlemail"]
    private static let attHostFragments = ["att.net", "mail.att", "sbcglobal", "bellsouth"]
    private static let yahooHostFragments = ["yahoo", "ymail", "rocketmail"]
    private static let aolHostFragments = ["aol"]
    private static let icloudHostSuffixes = ["mail.me.com", "mail.icloud.com"]
}
