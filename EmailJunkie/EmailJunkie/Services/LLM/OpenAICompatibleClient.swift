import Foundation

/// `LLMClient` adapter for any provider speaking the OpenAI
/// `/v1/chat/completions` wire format.
///
/// See https://platform.openai.com/docs/api-reference/chat. Auth is a
/// `Authorization: Bearer <key>` header. Because the endpoint is configurable,
/// one adapter covers OpenAI itself plus compatible gateways — OpenRouter, Groq,
/// Mistral, DeepSeek, Together, LM Studio, and Ollama's OpenAI-compat endpoint —
/// simply by pointing `baseURL` at each host.
struct OpenAICompatibleClient: LLMClient {
    let apiKey: String
    let transport: LLMHTTPTransport
    let baseURL: String?

    /// OpenAI's official chat-completions endpoint, used when the user hasn't
    /// supplied a custom base URL.
    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// - Parameter baseURL: a user-supplied base URL (e.g.
    ///   `https://openrouter.ai/api/v1`). Blank/`nil` falls back to OpenAI's
    ///   official endpoint. See `resolveEndpoint(baseURL:)` for normalization.
    init(
        apiKey: String,
        transport: LLMHTTPTransport,
        baseURL: String? = nil
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        // Resolve (and validate) the endpoint before touching the network so a
        // bad base URL fails fast — never silently routing the user's key to a
        // different host.
        let endpoint = try Self.resolveEndpoint(baseURL: baseURL)

        let body = try Self.encodeBody(request)
        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "content-type": "application/json"
        ]

        let response: HTTPResponse
        do {
            response = try await transport.postJSON(endpoint, headers: headers, body: body)
        } catch {
            throw LLMError.transport(String(describing: error))
        }

        guard response.isSuccess else {
            throw LLMError.http(status: response.statusCode, message: Self.errorMessage(from: response.body))
        }
        return try Self.parse(response.body)
    }

    // MARK: - Endpoint resolution

    /// Normalizes a user-supplied base URL into a full chat-completions endpoint.
    ///
    /// - Blank/`nil` → OpenAI's official endpoint.
    /// - A base ending in `/chat/completions` is used verbatim.
    /// - Otherwise `/chat/completions` is appended (trailing slashes trimmed),
    ///   so `https://openrouter.ai/api/v1` and `http://localhost:11434/v1`
    ///   both resolve correctly.
    ///
    /// Throws `LLMError.invalidBaseURL` for input that doesn't parse or whose
    /// scheme isn't `http`/`https` (e.g. an embedded space, or a scheme-less
    /// `openrouter.ai/api/v1`) rather than silently falling back to OpenAI —
    /// which would leak the user's key to the wrong host.
    static func resolveEndpoint(baseURL: String?) throws -> URL {
        let trimmed = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultEndpoint }

        var normalized = trimmed
        while normalized.hasSuffix("/") { normalized.removeLast() }

        let suffix = "/chat/completions"
        let full = normalized.hasSuffix(suffix) ? normalized : normalized + suffix

        guard let url = URL(string: full),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw LLMError.invalidBaseURL(trimmed)
        }
        return url
    }

    // MARK: - Wire format

    private static func encodeBody(_ request: LLMRequest) throws -> Data {
        // OpenAI folds the system prompt into the messages array as a leading
        // `system` role, rather than a top-level field the way Anthropic does.
        var messages: [RequestBody.Message] = []
        if let system = request.system, !system.isEmpty {
            messages.append(RequestBody.Message(role: "system", content: system))
        }
        messages.append(
            contentsOf: request.messages.map { RequestBody.Message(role: $0.role.rawValue, content: $0.content) }
        )

        let usesCompletionTokens = Self.usesMaxCompletionTokens(model: request.model)
        let body = RequestBody(
            model: request.model,
            messages: messages,
            maxTokens: usesCompletionTokens ? nil : request.maxTokens,
            maxCompletionTokens: usesCompletionTokens ? request.maxTokens : nil,
            temperature: Self.allowsSamplingParameters(model: request.model) ? request.temperature : nil
        )
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw LLMError.invalidResponse("Couldn't encode the request. (\(error))")
        }
    }

    private static func parse(_ data: Data) throws -> LLMResponse {
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Unexpected response shape. (\(error))")
        }
        let text = decoded.choices.first?.message?.content ?? ""
        return LLMResponse(
            text: text,
            inputTokens: decoded.usage?.promptTokens,
            outputTokens: decoded.usage?.completionTokens
        )
    }

    private static func errorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data),
           let message = decoded.error?.message, !message.isEmpty {
            return message
        }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            return raw
        }
        return "The provider returned an error."
    }

    // MARK: - Model quirks

    /// OpenAI's reasoning / next-generation model families reject the legacy
    /// `max_tokens` field and require `max_completion_tokens`. Compatible
    /// gateways generally accept `max_tokens`, so only these OpenAI-native
    /// families switch fields.
    static func usesMaxCompletionTokens(model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.hasPrefix("gpt-5")
    }

    /// The same reasoning families also reject a custom `temperature` (only the
    /// default is accepted), so it is omitted for them.
    private static func allowsSamplingParameters(model: String) -> Bool {
        !usesMaxCompletionTokens(model: model)
    }
}

// MARK: - Wire-format DTOs (file-private to keep type nesting shallow)

private struct RequestBody: Encodable {
    let model: String
    let messages: [Message]
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let temperature: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case temperature
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ResponseBody: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message?

        struct Message: Decodable {
            let content: String?
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

private struct ErrorBody: Decodable {
    let error: Detail?
    struct Detail: Decodable {
        let message: String?
    }
}
