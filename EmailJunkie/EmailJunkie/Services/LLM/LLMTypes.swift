import Foundation

/// A cloud LLM provider the user can select. Adding a provider is a matter of
/// adding a case here plus an `LLMClient` adapter — nothing else in the app
/// changes, which is what makes the layer pluggable.
enum LLMProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic

    var id: String { rawValue }

    /// Human-readable name for the Settings picker.
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        }
    }

    /// The model used when the user hasn't chosen one explicitly.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-6"
        }
    }

    /// The Keychain key holding this provider's API key.
    var apiKeySecret: SecretKey {
        .llmAPIKey(provider: rawValue)
    }
}

/// A single turn in a conversation sent to an LLM.
struct LLMMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

/// A provider-agnostic completion request. Adapters translate this into each
/// provider's wire format.
struct LLMRequest: Equatable, Sendable {
    var system: String?
    var messages: [LLMMessage]
    var model: String
    var maxTokens: Int
    var temperature: Double

    init(
        system: String? = nil,
        messages: [LLMMessage],
        model: String,
        maxTokens: Int = 1024,
        temperature: Double = 0.7
    ) {
        self.system = system
        self.messages = messages
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// A provider-agnostic completion result.
struct LLMResponse: Equatable, Sendable {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?

    init(text: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Errors surfaced by an `LLMClient`.
enum LLMError: Error, Equatable, Sendable {
    /// No API key was supplied.
    case missingAPIKey
    /// The network request itself failed (DNS, TLS, offline, …).
    case transport(String)
    /// The provider returned a non-2xx status with an optional message.
    case http(status: Int, message: String)
    /// The response was 2xx but couldn't be parsed into a completion.
    case invalidResponse(String)
}

/// A single-provider adapter: turns an `LLMRequest` into a completion by calling
/// one provider's API.
protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

/// The app-facing seam for verifying a provider's credentials. `AppState`
/// depends on this (not a concrete client) so connection tests are injectable.
protocol LLMConnectionTesting: Sendable {
    /// Sends a minimal request to confirm the key/model/endpoint work. Throws
    /// `LLMError` on any failure.
    func testConnection(provider: LLMProviderKind, apiKey: String, model: String) async throws
}
