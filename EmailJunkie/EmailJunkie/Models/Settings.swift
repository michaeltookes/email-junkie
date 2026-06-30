import Foundation

/// Non-secret application settings, persisted as JSON.
///
/// `schemaVersion` lets future versions migrate older files. Secrets are never
/// stored here — OAuth tokens and API keys live in the Keychain.
struct Settings: Codable, Equatable {

    /// The current settings schema version.
    static let currentSchemaVersion = 1

    /// Schema version of the persisted file.
    var schemaVersion: Int

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    var pollIntervalSeconds: Int

    /// Default settings for a fresh install.
    static let `default` = Settings(
        schemaVersion: currentSchemaVersion,
        pollIntervalSeconds: 300
    )

    /// Returns a copy with values clamped to sane ranges.
    func validated() -> Settings {
        var copy = self
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, 30), 3600)
        return copy
    }
}
