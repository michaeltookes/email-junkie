import XCTest
@testable import Sentwise

/// A `ManagedSessionProviding` double with a fixed token or a preset error.
private struct StubSessionProvider: ManagedSessionProviding {
    var token: String = "session-jwt"
    var error: Error?

    func currentSessionToken() async throws -> String {
        if let error { throw error }
        return token
    }
}

private actor RecordingSessionProvider: ManagedSessionProviding {
    private(set) var didInvalidate = false

    func currentSessionToken() async throws -> String {
        "session-jwt"
    }

    func invalidateSession() async {
        didInvalidate = true
    }
}

final class ManagedInferenceClientTests: XCTestCase {

    private func sampleRequest() -> LLMRequest {
        LLMRequest(
            system: "You write like the user.",
            messages: [LLMMessage(role: .user, content: "Draft a reply.")],
            model: "claude-sonnet-4-6",
            maxTokens: 512,
            temperature: 0.6
        )
    }

    private func json(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8))
    }

    func testSendsBearerTokenAndMapsResponse() async throws {
        let transport = FakeLLMTransport(response: json(
            #"{"text":"Hi Marcus,","usage":{"inputTokens":40,"outputTokens":12}}"#
        ))
        let client = ManagedInferenceClient(
            sessionProvider: StubSessionProvider(token: "tok-123"),
            transport: transport
        )

        let response = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL, ManagedInference.draftEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer tok-123")
        XCTAssertEqual(transport.lastHeaders?["content-type"], "application/json")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(object["system"] as? String, "You write like the user.")
        XCTAssertEqual(object["maxTokens"] as? Int, 512)
        XCTAssertEqual(object["temperature"] as? Double, 0.6)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "Draft a reply.")

        XCTAssertEqual(response.text, "Hi Marcus,")
        XCTAssertEqual(response.inputTokens, 40)
        XCTAssertEqual(response.outputTokens, 12)
    }

    func testMaps402ToManagedTrialExpiredWithServerMessage() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"trial_expired","message":"Your 14-day free trial has ended."}}"#,
            status: 402
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected trial-expired error")
        } catch LLMError.managedTrialExpired(let message) {
            XCTAssertEqual(message, "Your 14-day free trial has ended.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMaps401ToManagedNotSignedIn() async {
        let sessionProvider = RecordingSessionProvider()
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"unauthenticated","message":"Sign in."}}"#,
            status: 401
        ))
        let client = ManagedInferenceClient(sessionProvider: sessionProvider, transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            XCTAssertTrue(await sessionProvider.didInvalidate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMapsGenericServerErrorToHTTPWithMessage() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"overloaded","message":"The drafting service is temporarily overloaded."}}"#,
            status: 503
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected http error")
        } catch LLMError.http(let status, let message) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(message, "The drafting service is temporarily overloaded.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPropagatesNotSignedInFromSessionProviderWithoutCallingTransport() async {
        let transport = FakeLLMTransport(response: json("{}"))
        let client = ManagedInferenceClient(
            sessionProvider: StubSessionProvider(error: LLMError.managedNotSignedIn),
            transport: transport
        )

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            XCTAssertNil(transport.lastURL, "transport must not be called when not signed in")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
