import Foundation

/// Compile-time configuration for the Sentwise managed-inference service
/// (`sentwise-service`, backlog item 56a). The base URL is a constant with a
/// `SENTWISE_INFERENCE_URL` environment override for dev/tests pointing at a
/// local `wrangler dev` or a staging deployment.
enum ManagedInference {
    /// The deployed production Worker. Recorded here and in the service README.
    static let defaultBaseURLString = "https://sentwise-inference.sentwise-service.workers.dev"

    /// The base URL honoring the `SENTWISE_INFERENCE_URL` override.
    static var baseURL: URL {
        let override = ProcessInfo.processInfo.environment["SENTWISE_INFERENCE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty, let url = URL(string: override) {
            return url
        }
        // The default string is a compile-time constant we control, so this is safe.
        return URL(string: defaultBaseURLString)!
    }

    static var draftEndpoint: URL { baseURL.appendingPathComponent("v1/draft") }
    static var meEndpoint: URL { baseURL.appendingPathComponent("v1/me") }
}

/// Supplies a fresh, short-lived account session token for authenticating
/// managed-inference requests. Implemented by `ManagedAccountService`, which
/// mints tokens from Clerk on demand. Kept as a protocol so `ManagedInferenceClient`
/// stays testable against a fake without any account plumbing.
protocol ManagedSessionProviding: Sendable {
    /// Returns a session token valid *now*. Throws `LLMError.managedNotSignedIn`
    /// when there is no signed-in account. Implementations are expected to mint a
    /// fresh token per call (session tokens are short-lived), so callers never
    /// cache the result.
    func currentSessionToken() async throws -> String
}

/// A `ManagedSessionProviding` that always reports "not signed in". Used as the
/// default so a managed client constructed without an account wired in fails
/// with a clear, user-facing error instead of a crash.
struct UnavailableManagedSessionProvider: ManagedSessionProviding {
    func currentSessionToken() async throws -> String {
        throw LLMError.managedNotSignedIn
    }
}

/// `LLMClient` adapter for the Sentwise managed-inference proxy.
///
/// Mirrors `AnthropicClient` in shape, but authenticates with the account's
/// Clerk session token (Bearer) instead of a provider API key, and speaks the
/// thin `{ text, usage }` wire format the `sentwise-service` Worker returns.
struct ManagedInferenceClient: LLMClient {
    let sessionProvider: ManagedSessionProviding
    let transport: LLMHTTPTransport
    let endpoint: URL

    init(
        sessionProvider: ManagedSessionProviding,
        transport: LLMHTTPTransport,
        endpoint: URL = ManagedInference.draftEndpoint
    ) {
        self.sessionProvider = sessionProvider
        self.transport = transport
        self.endpoint = endpoint
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        // Mint a fresh session token for this request (tokens are short-lived).
        let token = try await sessionProvider.currentSessionToken()

        let body = try Self.encodeBody(request)
        let headers = [
            "authorization": "Bearer \(token)",
            "content-type": "application/json"
        ]

        let response: HTTPResponse
        do {
            response = try await transport.postJSON(endpoint, headers: headers, body: body)
        } catch {
            throw LLMError.transport(String(describing: error))
        }

        guard response.isSuccess else {
            throw Self.mapError(status: response.statusCode, body: response.body)
        }
        return try Self.parse(response.body)
    }

    // MARK: - Wire format

    private static func encodeBody(_ request: LLMRequest) throws -> Data {
        let body = RequestBody(
            model: request.model,
            system: request.system,
            messages: request.messages.map { RequestBody.Message(role: $0.role.rawValue, content: $0.content) },
            maxTokens: request.maxTokens,
            temperature: request.temperature
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
        return LLMResponse(
            text: decoded.text,
            inputTokens: decoded.usage?.inputTokens,
            outputTokens: decoded.usage?.outputTokens
        )
    }

    /// Maps a structured Worker error into a clear, user-facing `LLMError`. The
    /// Worker's messages are already user-safe (no raw upstream detail), so we
    /// surface them directly; only the transport-level shape is translated.
    private static func mapError(status: Int, body: Data) -> LLMError {
        let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body)
        let type = decoded?.error?.type ?? ""
        let message = decoded?.error?.message

        switch status {
        case 401:
            return .managedNotSignedIn
        case 402:
            return .managedTrialExpired(message ?? "Your Sentwise AI trial has ended.")
        default:
            if type == "trial_expired" {
                return .managedTrialExpired(message ?? "Your Sentwise AI trial has ended.")
            }
            return .http(status: status, message: message ?? "The drafting service returned an error.")
        }
    }
}

/// A deterministic, zero-network managed client used in Prowl hunt mode so
/// hunts stay offline-safe (backlog 56a). Never touches the transport or the
/// session provider.
struct StubManagedInferenceClient: LLMClient {
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(
            text: "This is a canned Sentwise AI response for offline Prowl hunts.",
            inputTokens: 0,
            outputTokens: 0
        )
    }
}

// MARK: - Wire-format DTOs (file-private)

private struct RequestBody: Encodable {
    let model: String
    let system: String?
    let messages: [Message]
    let maxTokens: Int
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens
        case temperature
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ResponseBody: Decodable {
    let text: String
    let usage: Usage?

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
    }
}

private struct ErrorBody: Decodable {
    let error: Detail?
    struct Detail: Decodable {
        let type: String?
        let message: String?
    }
}
