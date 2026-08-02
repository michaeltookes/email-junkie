import Foundation

/// A cloud LLM provider the user can select. Adding a provider is a matter of
/// adding a case here plus an `LLMClient` adapter — nothing else in the app
/// changes, which is what makes the layer pluggable.
enum LLMProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic
    /// Any provider speaking the OpenAI `/v1/chat/completions` wire format. A
    /// single adapter covers OpenAI itself plus every compatible gateway
    /// (OpenRouter, Groq, Mistral, DeepSeek, Together, LM Studio, Ollama's
    /// OpenAI-compat endpoint, …) by pointing the base URL at each host.
    case openAICompatible

    var id: String { rawValue }

    /// Human-readable name for the Settings picker.
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// The model used when the user hasn't chosen one explicitly.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-6"
        case .openAICompatible: return "gpt-4o-mini"
        }
    }

    /// Whether the user may override the provider's HTTP endpoint. Only the
    /// OpenAI-compatible adapter is endpoint-configurable; that override is what
    /// lets one adapter target OpenAI or any BYO gateway/proxy.
    var supportsCustomBaseURL: Bool {
        switch self {
        case .anthropic: return false
        case .openAICompatible: return true
        }
    }

    /// A placeholder base URL shown in the Settings field, or `nil` for
    /// providers whose endpoint isn't user-configurable.
    var baseURLPlaceholder: String? {
        switch self {
        case .anthropic: return nil
        case .openAICompatible: return "https://api.openai.com/v1"
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
    /// The configured custom base URL isn't a valid http(s) endpoint, so the
    /// request was not sent (the trimmed value is carried for the message).
    case invalidBaseURL(String)
}

/// A single-provider adapter: turns an `LLMRequest` into a completion by calling
/// one provider's API.
protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

/// The app-facing seam for the LLM layer: verify credentials and run
/// completions. `AppState` depends on this (not a concrete client) so both are
/// injectable in tests without hitting the network.
protocol LLMProviding: Sendable {
    /// Sends a minimal request to confirm the key/model/endpoint work. Throws
    /// `LLMError` on any failure. `baseURL` overrides the provider's default
    /// endpoint (only honored by adapters where `supportsCustomBaseURL` is true);
    /// pass `nil` for the provider default.
    func testConnection(
        provider: LLMProviderKind,
        apiKey: String,
        model: String,
        baseURL: String?
    ) async throws

    /// Runs a completion against the given provider with the supplied key.
    /// `baseURL` overrides the provider's default endpoint (see `testConnection`).
    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse
}

extension LLMProviding {
    /// Convenience for callers that don't override the endpoint (e.g. the
    /// Anthropic path and existing tests): forwards with the provider default.
    func testConnection(provider: LLMProviderKind, apiKey: String, model: String) async throws {
        try await testConnection(provider: provider, apiKey: apiKey, model: model, baseURL: nil)
    }

    /// Convenience for callers that don't override the endpoint.
    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String
    ) async throws -> LLMResponse {
        try await complete(request, provider: provider, apiKey: apiKey, baseURL: nil)
    }
}
