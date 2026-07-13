import Foundation

/// Credentials for connecting to a mailbox over IMAP with an app password.
///
/// Defaults target Gmail; `host`/`port` are overridable for other providers.
public struct MailAccountCredentials: Equatable, Sendable {
    public var email: String
    public var appPassword: String
    public var host: String
    public var port: Int
    /// The SMTP submission host used for sending. Defaults to the IMAP host with
    /// its `imap.` prefix swapped for `smtp.` (Gmail: `smtp.gmail.com`).
    public var smtpHost: String
    /// The SMTP submission port. Defaults to 465 (implicit TLS / SMTPS).
    public var smtpPort: Int

    public init(
        email: String,
        appPassword: String,
        host: String = "imap.gmail.com",
        port: Int = 993,
        smtpHost: String? = nil,
        smtpPort: Int = 465
    ) {
        self.email = email
        self.appPassword = appPassword
        self.host = host
        self.port = port
        self.smtpHost = smtpHost ?? Self.derivedSMTPHost(from: host)
        self.smtpPort = smtpPort
    }

    /// Whether all required fields are present.
    public var isComplete: Bool {
        !email.isEmpty && !appPassword.isEmpty && !host.isEmpty && port > 0
    }

    /// Derives an SMTP submission host from an IMAP host by swapping a leading
    /// `imap.` for `smtp.`; other hosts are returned unchanged.
    static func derivedSMTPHost(from host: String) -> String {
        host.hasPrefix("imap.") ? "smtp." + host.dropFirst("imap.".count) : host
    }
}
