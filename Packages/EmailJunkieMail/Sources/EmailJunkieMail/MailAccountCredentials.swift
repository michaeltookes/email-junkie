import Foundation

/// Credentials for connecting to a mailbox over IMAP with an app password.
///
/// Defaults target Gmail; `host`/`port` are overridable for other providers.
public struct MailAccountCredentials: Equatable, Sendable {
    public var email: String
    public var appPassword: String
    public var host: String
    public var port: Int

    public init(
        email: String,
        appPassword: String,
        host: String = "imap.gmail.com",
        port: Int = 993
    ) {
        self.email = email
        self.appPassword = appPassword
        self.host = host
        self.port = port
    }

    /// Whether all required fields are present.
    public var isComplete: Bool {
        !email.isEmpty && !appPassword.isEmpty && !host.isEmpty && port > 0
    }
}
