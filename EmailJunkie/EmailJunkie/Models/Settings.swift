import Foundation

/// Non-secret application settings, persisted as JSON.
///
/// `schemaVersion` lets future versions migrate older files, and unknown/missing
/// keys decode to defaults. Secrets are never stored here — the mail app
/// password lives in the Keychain.
struct Settings: Codable, Equatable {

    /// The current settings schema version.
    static let currentSchemaVersion = 3

    /// Schema version of the persisted file.
    var schemaVersion: Int

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    var pollIntervalSeconds: Int

    /// The connected mailbox email address (non-secret).
    var mailEmail: String

    /// The IMAP host.
    var mailHost: String

    /// The IMAP port.
    var mailPort: Int

    /// The selected LLM provider (raw value of `LLMProviderKind`). Stored as a
    /// string so an unknown/future provider decodes gracefully to the default.
    var llmProvider: String

    /// The chosen model id, or empty to use the provider's default model.
    var llmModel: String

    init(
        schemaVersion: Int,
        pollIntervalSeconds: Int,
        mailEmail: String = "",
        mailHost: String = "imap.gmail.com",
        mailPort: Int = 993,
        llmProvider: String = "anthropic",
        llmModel: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.pollIntervalSeconds = pollIntervalSeconds
        self.mailEmail = mailEmail
        self.mailHost = mailHost
        self.mailPort = mailPort
        self.llmProvider = llmProvider
        self.llmModel = llmModel
    }

    /// Default settings for a fresh install.
    static let `default` = Settings(
        schemaVersion: currentSchemaVersion,
        pollIntervalSeconds: 300
    )

    enum CodingKeys: String, CodingKey {
        case schemaVersion, pollIntervalSeconds, mailEmail, mailHost, mailPort, llmProvider, llmModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Settings.currentSchemaVersion
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300
        mailEmail = try container.decodeIfPresent(String.self, forKey: .mailEmail) ?? ""
        mailHost = try container.decodeIfPresent(String.self, forKey: .mailHost) ?? "imap.gmail.com"
        mailPort = try container.decodeIfPresent(Int.self, forKey: .mailPort) ?? 993
        llmProvider = try container.decodeIfPresent(String.self, forKey: .llmProvider) ?? "anthropic"
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? ""
    }

    /// Returns a copy with values clamped to sane ranges.
    func validated() -> Settings {
        var copy = self
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, 30), 3600)
        copy.mailPort = min(max(mailPort, 1), 65535)
        if copy.mailHost.isEmpty {
            copy.mailHost = "imap.gmail.com"
        }
        return copy
    }
}
