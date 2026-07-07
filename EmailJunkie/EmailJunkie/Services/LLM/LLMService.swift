import Foundation

/// Resolves the selected provider + API key into a concrete `LLMClient` and
/// exposes the operations the app needs. Production entry point for the LLM
/// layer; `AppState` talks to it through `LLMProviding`.
struct LLMService: LLMProviding {
    let transport: LLMHTTPTransport

    init(transport: LLMHTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Builds the adapter for a provider.
    private func client(for provider: LLMProviderKind, apiKey: String) -> LLMClient {
        switch provider {
        case .anthropic:
            return AnthropicClient(apiKey: apiKey, transport: transport)
        }
    }

    /// Verifies credentials with a tiny, cheap request.
    func testConnection(provider: LLMProviderKind, apiKey: String, model: String) async throws {
        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: "Reply with the single word: OK")],
            model: model,
            maxTokens: 16,
            temperature: 0
        )
        _ = try await client(for: provider, apiKey: apiKey).complete(request)
    }

    /// Runs a completion against the selected provider. (Used by the draft
    /// engine in a later slice.)
    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String
    ) async throws -> LLMResponse {
        try await client(for: provider, apiKey: apiKey).complete(request)
    }
}
