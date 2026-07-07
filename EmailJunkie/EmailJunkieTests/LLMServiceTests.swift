import XCTest
@testable import EmailJunkie

final class LLMServiceTests: XCTestCase {

    func testTestConnectionSendsMinimalRequestWithChosenModel() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 200,
            body: Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        try await service.testConnection(provider: .anthropic, apiKey: "sk-test", model: "claude-haiku-4-5-20251001")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertEqual(transport.lastHeaders?["x-api-key"], "sk-test")
    }

    func testTestConnectionSurfacesProviderError() async {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 401,
            body: Data(#"{"error":{"message":"bad key"}}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        do {
            try await service.testConnection(provider: .anthropic, apiKey: "nope", model: "claude-sonnet-4-6")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .http(status: 401, message: "bad key"))
        }
    }
}
