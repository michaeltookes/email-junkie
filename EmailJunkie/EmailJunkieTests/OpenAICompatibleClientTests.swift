import XCTest
@testable import EmailJunkie

final class OpenAICompatibleClientTests: XCTestCase {

    private func client(
        _ response: HTTPResponse,
        key: String = "sk-test",
        baseURL: String? = nil
    ) -> (OpenAICompatibleClient, FakeLLMTransport) {
        let transport = FakeLLMTransport(response: response)
        return (OpenAICompatibleClient(apiKey: key, transport: transport, baseURL: baseURL), transport)
    }

    /// A key-optional (local) client mirroring how `LLMService` builds the
    /// Ollama provider: no key required, Ollama's loopback default endpoint.
    private func localClient(
        _ response: HTTPResponse,
        key: String = "",
        baseURL: String? = nil
    ) -> (OpenAICompatibleClient, FakeLLMTransport) {
        let transport = FakeLLMTransport(response: response)
        let client = OpenAICompatibleClient(
            apiKey: key,
            transport: transport,
            baseURL: baseURL,
            defaultEndpoint: OpenAICompatibleClient.ollamaDefaultEndpoint,
            requiresAPIKey: false
        )
        return (client, transport)
    }

    private func json(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8))
    }

    private func okResponse() -> HTTPResponse {
        json(#"{"choices":[{"message":{"content":"Hello"}}]}"#)
    }

    private func sampleRequest(model: String = "gpt-4o-mini") -> LLMRequest {
        LLMRequest(
            system: "You are helpful.",
            messages: [LLMMessage(role: .user, content: "Hi")],
            model: model,
            maxTokens: 32,
            temperature: 0.5
        )
    }

    // MARK: - Request encoding

    func testEncodesRequestBodyAuthHeadersAndDefaultEndpoint() async throws {
        let (client, transport) = client(okResponse())

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(transport.lastHeaders?["Authorization"], "Bearer sk-test")
        XCTAssertEqual(transport.lastHeaders?["content-type"], "application/json")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(object["max_tokens"] as? Int, 32)
        XCTAssertNil(object["max_completion_tokens"])
        XCTAssertEqual(object["temperature"] as? Double, 0.5)
    }

    func testFoldsSystemPromptIntoLeadingSystemMessage() async throws {
        let (client, transport) = client(okResponse())

        _ = try await client.complete(sampleRequest())

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "You are helpful.")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "Hi")
    }

    func testOmitsSystemMessageWhenNoSystemPrompt() async throws {
        let (client, transport) = client(okResponse())
        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: "Hi")],
            model: "gpt-4o-mini",
            maxTokens: 32,
            temperature: 0.5
        )

        _ = try await client.complete(request)

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    // MARK: - Base URL resolution

    func testResolvesCustomBaseURLByAppendingChatCompletions() async throws {
        let (client, transport) = client(okResponse(), baseURL: "https://openrouter.ai/api/v1")

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
    }

    func testResolvesBaseURLWithTrailingSlash() async throws {
        let (client, transport) = client(okResponse(), baseURL: "http://localhost:11434/v1/")

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testResolvesBaseURLWithQueryByAppendingPathBeforeQuery() async throws {
        let (client, transport) = client(okResponse(), baseURL: "https://gateway.example.com/v1?tenant=x")

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL?.absoluteString, "https://gateway.example.com/v1/chat/completions?tenant=x")
    }

    func testUsesBaseURLVerbatimWhenItAlreadyTargetsChatCompletions() async throws {
        let (client, transport) = client(
            okResponse(),
            baseURL: "https://gateway.example.com/v1/chat/completions"
        )

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL?.absoluteString, "https://gateway.example.com/v1/chat/completions")
    }

    func testUsesFullEndpointWithQueryAndFragmentVerbatim() async throws {
        let (client, transport) = client(
            okResponse(),
            baseURL: "https://gateway.example.com/v1/chat/completions?tenant=x#primary"
        )

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(
            transport.lastURL?.absoluteString,
            "https://gateway.example.com/v1/chat/completions?tenant=x#primary"
        )
    }

    func testBlankBaseURLFallsBackToDefaultEndpoint() throws {
        XCTAssertEqual(try OpenAICompatibleClient.resolveEndpoint(baseURL: nil), OpenAICompatibleClient.defaultEndpoint)
        XCTAssertEqual(try OpenAICompatibleClient.resolveEndpoint(baseURL: ""), OpenAICompatibleClient.defaultEndpoint)
        XCTAssertEqual(try OpenAICompatibleClient.resolveEndpoint(baseURL: "   "), OpenAICompatibleClient.defaultEndpoint)
    }

    func testResolveEndpointRejectsUnparseableAndSchemelessInput() {
        // An embedded space doesn't parse; a scheme-less host parses but has no
        // scheme; a non-http scheme is rejected. None may fall back to OpenAI.
        for bad in ["https://my host/v1", "openrouter.ai/api/v1", "ftp://example.com/v1", "://nohost/v1"] {
            XCTAssertThrowsError(try OpenAICompatibleClient.resolveEndpoint(baseURL: bad), "expected \(bad) to throw") { error in
                guard case .invalidBaseURL(let value) = error as? LLMError else {
                    return XCTFail("expected .invalidBaseURL for \(bad), got \(error)")
                }
                XCTAssertEqual(value, bad)
            }
        }
    }

    func testInvalidBaseURLThrowsBeforeCallingTransport() async {
        let transport = FakeLLMTransport(response: okResponse())
        let client = OpenAICompatibleClient(apiKey: "sk-test", transport: transport, baseURL: "openrouter.ai/api/v1")

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .invalidBaseURL("openrouter.ai/api/v1"))
        }
        XCTAssertNil(transport.lastURL, "transport must not be called for an invalid base URL")
    }

    // MARK: - Key-optional (local) behavior

    func testKeyOptionalClientResolvesLocalDefaultEndpointWhenBaseURLBlank() async throws {
        let (client, transport) = localClient(okResponse())

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testKeyOptionalClientOmitsAuthorizationHeaderWhenKeyEmpty() async throws {
        let (client, transport) = localClient(okResponse())

        _ = try await client.complete(sampleRequest())

        XCTAssertNil(transport.lastHeaders?["Authorization"], "no bare Bearer header when the key is empty")
        XCTAssertEqual(transport.lastHeaders?["content-type"], "application/json")
    }

    func testKeyOptionalClientSucceedsWithEmptyKey() async throws {
        // A cloud client with an empty key throws; the key-optional one does not.
        let (client, transport) = localClient(okResponse())

        let response = try await client.complete(sampleRequest())

        XCTAssertEqual(response.text, "Hello")
        XCTAssertNotNil(transport.lastURL, "the request must be sent even without a key")
    }

    func testKeyOptionalClientStillSendsAuthorizationWhenKeyProvided() async throws {
        // Pointing the local provider at a keyed LAN gateway still authenticates.
        let (client, transport) = localClient(okResponse(), key: "lan-key")

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastHeaders?["Authorization"], "Bearer lan-key")
    }

    func testKeyOptionalClientRoutesCustomBaseURLToLMStudio() async throws {
        let (client, transport) = localClient(okResponse(), baseURL: "http://localhost:1234/v1")

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL?.absoluteString, "http://localhost:1234/v1/chat/completions")
    }

    func testResolveEndpointHonorsCustomDefaultForBlankInput() throws {
        XCTAssertEqual(
            try OpenAICompatibleClient.resolveEndpoint(
                baseURL: nil,
                defaultEndpoint: OpenAICompatibleClient.ollamaDefaultEndpoint
            ),
            OpenAICompatibleClient.ollamaDefaultEndpoint
        )
        XCTAssertEqual(
            try OpenAICompatibleClient.resolveEndpoint(
                baseURL: "   ",
                defaultEndpoint: OpenAICompatibleClient.ollamaDefaultEndpoint
            ),
            OpenAICompatibleClient.ollamaDefaultEndpoint
        )
    }

    // MARK: - Model quirks

    func testUsesMaxCompletionTokensAndOmitsTemperatureForReasoningModels() async throws {
        let models = ["o1", "o1-mini", "o3-mini", "o4-mini", "gpt-5", "gpt-5-mini"]

        for model in models {
            let (client, transport) = client(okResponse())
            _ = try await client.complete(sampleRequest(model: model))

            let body = try XCTUnwrap(transport.lastBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["max_completion_tokens"] as? Int, 32, "expected \(model) to use max_completion_tokens")
            XCTAssertNil(object["max_tokens"], "expected \(model) to omit max_tokens")
            XCTAssertNil(object["temperature"], "expected \(model) to omit temperature")
        }
    }

    func testUsesMaxTokensAndKeepsTemperatureForStandardModels() async throws {
        let models = ["gpt-4o-mini", "gpt-4o", "gpt-4.1", "mistral-large-latest", "llama-3.1-8b-instruct"]

        for model in models {
            let (client, transport) = client(okResponse())
            _ = try await client.complete(sampleRequest(model: model))

            let body = try XCTUnwrap(transport.lastBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["max_tokens"] as? Int, 32, "expected \(model) to use max_tokens")
            XCTAssertNil(object["max_completion_tokens"], "expected \(model) to omit max_completion_tokens")
            XCTAssertEqual(object["temperature"] as? Double, 0.5, "expected \(model) to keep temperature")
        }
    }

    // MARK: - Response parsing

    func testParsesContentAndUsage() async throws {
        let (client, _) = client(json(#"""
        {"choices":[{"message":{"role":"assistant","content":"Hello there"}}],
         "usage":{"prompt_tokens":12,"completion_tokens":3}}
        """#))

        let response = try await client.complete(sampleRequest())

        XCTAssertEqual(response.text, "Hello there")
        XCTAssertEqual(response.inputTokens, 12)
        XCTAssertEqual(response.outputTokens, 3)
    }

    func testParsesEmptyChoicesToEmptyText() async throws {
        let (client, _) = client(json(#"{"choices":[]}"#))

        let response = try await client.complete(sampleRequest())

        XCTAssertEqual(response.text, "")
        XCTAssertNil(response.inputTokens)
        XCTAssertNil(response.outputTokens)
    }

    // MARK: - Errors

    func testMissingKeyThrowsBeforeCallingTransport() async {
        let transport = FakeLLMTransport(response: json("{}"))
        let client = OpenAICompatibleClient(apiKey: "", transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .missingAPIKey)
        }
        XCTAssertNil(transport.lastURL, "transport must not be called without a key")
    }

    func testNonSuccessStatusSurfacesParsedErrorMessage() async {
        let (client, _) = client(
            json(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#, status: 401)
        )

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .http(status: 401, message: "Incorrect API key provided"))
        }
    }

    func testTransportFailureMapsToTransportError() async {
        let transport = FakeLLMTransport(error: URLError(.notConnectedToInternet))
        let client = OpenAICompatibleClient(apiKey: "sk-test", transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            guard case .transport = error as? LLMError else {
                return XCTFail("expected .transport, got \(error)")
            }
        }
    }

    func testUnparseableSuccessBodySurfacesInvalidResponse() async {
        let (client, _) = client(json("not json", status: 200))

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            guard case .invalidResponse = error as? LLMError else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }
}
