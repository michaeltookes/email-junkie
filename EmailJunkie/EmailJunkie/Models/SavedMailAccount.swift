import Foundation

/// A remembered email account the user can switch to without re-entering
/// credentials (item 48). Holds only the non-secret connection details —
/// email, IMAP host, and port. The app password is **never** stored here;
/// it lives in the macOS Keychain under a per-account key
/// (`SecretKey.mailAppPassword(email:)`), so removing an account can delete
/// exactly its secret and nothing leaks into the plaintext settings file.
struct SavedMailAccount: Codable, Equatable, Identifiable {
    /// The account's email address (as the user entered it, for display).
    var email: String
    /// The IMAP host this account connects through.
    var host: String
    /// The IMAP port this account connects through.
    var port: Int

    /// A stable identity derived from the normalized email, so the same mailbox
    /// under different casing/whitespace is treated as one account. This is also
    /// the discriminator used to derive the per-account Keychain key, so it must
    /// match `SecretKey.mailAppPassword(email:)`'s normalization.
    var id: String { Self.normalizedEmail(email) }

    init(email: String, host: String, port: Int) {
        self.email = email
        self.host = host
        self.port = port
    }

    /// Lower-cased, whitespace-trimmed email — the canonical account identity.
    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
