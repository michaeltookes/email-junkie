import Foundation

/// What happens when the user approves a generated draft.
enum SendBehavior: String, CaseIterable, Equatable {
    /// Create a Gmail draft via IMAP `APPEND` (nothing is sent).
    case saveAsDraft
    /// Send the reply immediately over SMTP.
    case autoSend

    /// The safer default: save a draft rather than send automatically.
    static let `default`: SendBehavior = .saveAsDraft
}

/// Non-secret application settings, persisted as JSON.
///
/// `schemaVersion` lets future versions migrate older files, and unknown/missing
/// keys decode to defaults. Secrets are never stored here — the mail app
/// password lives in the Keychain.
struct Settings: Codable, Equatable {

    /// The current settings schema version.
    static let currentSchemaVersion = 6

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

    /// The resolved model id that last passed a connection test.
    var llmVerifiedModel: String

    /// What approving a draft does (raw value of `SendBehavior`). Stored as a
    /// string so an unknown/future value decodes gracefully to the default.
    var sendBehavior: String

    /// Whether the user has finished (or explicitly dismissed) the first-run
    /// onboarding flow. Old files without this key decode to `false`; an
    /// already-configured install is treated as complete at launch.
    var onboardingCompleted: Bool

    init(
        schemaVersion: Int,
        pollIntervalSeconds: Int,
        mailEmail: String = "",
        mailHost: String = "imap.gmail.com",
        mailPort: Int = 993,
        llmProvider: String = "anthropic",
        llmModel: String = "",
        llmVerifiedModel: String = "",
        sendBehavior: String = SendBehavior.default.rawValue,
        onboardingCompleted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.pollIntervalSeconds = pollIntervalSeconds
        self.mailEmail = mailEmail
        self.mailHost = mailHost
        self.mailPort = mailPort
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmVerifiedModel = llmVerifiedModel
        self.sendBehavior = sendBehavior
        self.onboardingCompleted = onboardingCompleted
    }

    /// Default settings for a fresh install.
    static let `default` = Settings(
        schemaVersion: currentSchemaVersion,
        pollIntervalSeconds: 300
    )

    enum CodingKeys: String, CodingKey {
        case schemaVersion, pollIntervalSeconds, mailEmail, mailHost, mailPort
        case llmProvider, llmModel, llmVerifiedModel, sendBehavior, onboardingCompleted
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
        llmVerifiedModel = try container.decodeIfPresent(String.self, forKey: .llmVerifiedModel) ?? ""
        sendBehavior = try container.decodeIfPresent(String.self, forKey: .sendBehavior) ?? SendBehavior.default.rawValue
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
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
