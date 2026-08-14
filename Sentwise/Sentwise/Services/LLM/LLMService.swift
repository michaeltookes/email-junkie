import Foundation

/// Resolves the selected provider + API key into a concrete `LLMClient` and
/// exposes the operations the app needs. Production entry point for the LLM
/// layer; `AppState` talks to it through `LLMProviding`.
struct LLMService: LLMProviding {
    let transport: LLMHTTPTransport

    init(transport: LLMHTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Builds the adapter for a provider. `baseURL` is honored only by adapters
    /// whose `supportsCustomBaseURL` is true (the OpenAI-compatible and local
    /// ones); other adapters ignore it.
    private func client(for provider: LLMProviderKind, apiKey: String, baseURL: String?) -> LLMClient {
        switch provider {
        case .anthropic:
            return AnthropicClient(apiKey: apiKey, transport: transport)
        case .openAICompatible, .ollama:
            // One adapter serves both: the local provider only differs by its
            // default endpoint (Ollama's loopback) and key-optional auth.
            return OpenAICompatibleClient(
                apiKey: apiKey,
                transport: transport,
                baseURL: baseURL,
                defaultEndpoint: provider.defaultOpenAICompatibleEndpoint ?? OpenAICompatibleClient.defaultEndpoint,
                requiresAPIKey: provider.requiresAPIKey
            )
        }
    }

    /// Verifies credentials with a tiny, cheap request.
    func testConnection(
        provider: LLMProviderKind,
        apiKey: String,
        model: String,
        baseURL: String?
    ) async throws {
        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: "Reply with the single word: OK")],
            model: model,
            maxTokens: 16,
            temperature: 0
        )
        _ = try await client(for: provider, apiKey: apiKey, baseURL: baseURL).complete(request)
    }

    /// Runs a completion against the selected provider. (Used by the draft
    /// engine in a later slice.)
    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        try await client(for: provider, apiKey: apiKey, baseURL: baseURL).complete(request)
    }
}
