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
    static let currentSchemaVersion = 9

    /// Schema version that introduced the persisted onboarding completion flag.
    static let onboardingCompletionSchemaVersion = 6

    /// Schema version that introduced persisted IMAP host guidance ownership.
    static let mailHostGuidanceSchemaVersion = 7

    /// Schema version that introduced host ownership before an email is entered.
    static let pendingMailHostGuidanceSchemaVersion = 8

    /// Schema version that introduced the per-provider custom LLM base URL.
    static let llmBaseURLSchemaVersion = 9

    /// Schema version of the persisted file.
    var schemaVersion: Int

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    var pollIntervalSeconds: Int

    /// The connected mailbox email address (non-secret).
    var mailEmail: String

    /// The IMAP host.
    var mailHost: String

    /// Email address the configured host was explicitly or successfully tied to.
    var mailHostGuidanceEmail: String?

    /// Whether the configured host was explicitly entered before an email existed.
    var mailHostGuidancePendingEmail: Bool

    /// The IMAP port.
    var mailPort: Int

    /// The selected LLM provider (raw value of `LLMProviderKind`). Stored as a
    /// string so an unknown/future provider decodes gracefully to the default.
    var llmProvider: String

    /// The chosen model id, or empty to use the provider's default model.
    var llmModel: String

    /// An optional custom base URL for the selected provider (BYO gateway/proxy).
    /// Empty means the provider's default endpoint. Only honored by providers
    /// whose `supportsCustomBaseURL` is true (the OpenAI-compatible adapter).
    var llmBaseURL: String

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
        mailHostGuidanceEmail: String? = nil,
        mailHostGuidancePendingEmail: Bool = false,
        mailPort: Int = 993,
        llmProvider: String = "anthropic",
        llmModel: String = "",
        llmBaseURL: String = "",
        llmVerifiedModel: String = "",
        sendBehavior: String = SendBehavior.default.rawValue,
        onboardingCompleted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.pollIntervalSeconds = pollIntervalSeconds
        self.mailEmail = mailEmail
        self.mailHost = mailHost
        self.mailHostGuidanceEmail = mailHostGuidanceEmail
        self.mailHostGuidancePendingEmail = mailHostGuidancePendingEmail
        self.mailPort = mailPort
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmBaseURL = llmBaseURL
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
        case schemaVersion, pollIntervalSeconds, mailEmail, mailHost, mailHostGuidanceEmail
        case mailHostGuidancePendingEmail, mailPort
        case llmProvider, llmModel, llmBaseURL, llmVerifiedModel, sendBehavior, onboardingCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Settings.currentSchemaVersion
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300
        mailEmail = try container.decodeIfPresent(String.self, forKey: .mailEmail) ?? ""
        mailHost = try container.decodeIfPresent(String.self, forKey: .mailHost) ?? "imap.gmail.com"
        mailHostGuidanceEmail = try container.decodeIfPresent(String.self, forKey: .mailHostGuidanceEmail)
        mailHostGuidancePendingEmail =
            try container.decodeIfPresent(Bool.self, forKey: .mailHostGuidancePendingEmail) ?? false
        mailPort = try container.decodeIfPresent(Int.self, forKey: .mailPort) ?? 993
        llmProvider = try container.decodeIfPresent(String.self, forKey: .llmProvider) ?? "anthropic"
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? ""
        llmBaseURL = try container.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
        llmVerifiedModel = try container.decodeIfPresent(String.self, forKey: .llmVerifiedModel) ?? ""
        sendBehavior = try container.decodeIfPresent(String.self, forKey: .sendBehavior) ?? SendBehavior.default.rawValue
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    }

    /// Returns a copy with values clamped to sane ranges.
    func validated() -> Settings {
        var copy = self
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, 30), 3600)
        copy.mailPort = min(max(mailPort, 1), 65535)
        copy.llmBaseURL = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStoredGuidanceHost = !copy.mailHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if copy.mailHost.isEmpty && copy.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.mailHost = "imap.gmail.com"
        }
        if let guidanceEmail = copy.mailHostGuidanceEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !guidanceEmail.isEmpty {
            copy.mailHostGuidanceEmail = guidanceEmail
        } else {
            copy.mailHostGuidanceEmail = nil
        }
        if copy.mailHostGuidancePendingEmail,
           !hasStoredGuidanceHost {
            copy.mailHostGuidancePendingEmail = false
        }
        return copy
    }
}
