import Foundation

/// A typed key identifying a secret in a `SecretStore`.
///
/// Using a `RawRepresentable` struct (rather than an enum) lets us define
/// stable well-known keys *and* derive per-provider keys at runtime.
struct SecretKey: RawRepresentable, Hashable {
    let rawValue: String

    // MARK: Well-known keys

    /// The Gmail OAuth token set (access + refresh + expiry), stored as JSON.
    /// (OAuth path is parked; kept for a future bundled-client revival.)
    static let gmailToken = SecretKey(rawValue: "gmail.token")
    /// The mailbox app password used for IMAP/SMTP authentication.
    static let mailAppPassword = SecretKey(rawValue: "mail.appPassword")
    /// The user-supplied Google Cloud OAuth client ID (BYO credentials).
    static let googleClientID = SecretKey(rawValue: "google.clientID")
    /// The user-supplied Google Cloud OAuth client secret (BYO credentials).
    static let googleClientSecret = SecretKey(rawValue: "google.clientSecret")

    /// The API key for a specific LLM provider (e.g. `"anthropic"`, `"openai"`).
    static func llmAPIKey(provider: String) -> SecretKey {
        SecretKey(rawValue: "llm.\(provider).apiKey")
    }
}

/// Secure storage for sensitive strings — OAuth tokens, API keys, client secrets.
///
/// Implemented by `KeychainStore` in production and `InMemorySecretStore` in
/// tests/previews. Secrets never touch the plaintext settings file; everything
/// sensitive goes through here. This is the backbone of the local-first privacy
/// promise.
protocol SecretStore {
    /// Stores `value` for `key`, replacing any existing value.
    func set(_ value: String, for key: SecretKey) throws
    /// Returns the stored value for `key`, or `nil` if absent.
    func value(for key: SecretKey) throws -> String?
    /// Removes the value for `key`. No-op if absent.
    func remove(_ key: SecretKey) throws
    /// Removes every secret owned by this store (used on full disconnect/reset).
    func removeAll() throws
}

extension SecretStore {
    /// Whether a non-empty value exists for `key`.
    func hasValue(for key: SecretKey) -> Bool {
        let stored = (try? value(for: key)) ?? nil
        return stored?.isEmpty == false
    }
}

/// A non-persistent `SecretStore` for tests and SwiftUI previews.
final class InMemorySecretStore: SecretStore {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    init(seed: [SecretKey: String] = [:]) {
        for (key, value) in seed {
            storage[key.rawValue] = value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
