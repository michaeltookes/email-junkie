import XCTest
@testable import Sentwise

/// A `ManagedSessionProviding` returning a pre-obtained live session token.
private struct EnvSessionProvider: ManagedSessionProviding {
    let token: String
    func currentSessionToken() async throws -> String { token }
}

/// End-to-end tests against the deployed `sentwise-service` Worker. Skipped
/// unless BOTH env vars are set, so CI and normal runs stay offline:
///   SENTWISE_LIVE_CLERK_SESSION_TOKEN  — a real Clerk session JWT
///   SENTWISE_INFERENCE_URL             — the deployed Worker base URL
///
/// Obtain a session token by signing in through the app (or via Clerk) and
/// reading the minted token; it is short-lived, so run these promptly.
final class ManagedInferenceLiveTests: XCTestCase {

    private func liveConfig() throws -> (token: String, baseURL: URL) {
        let env = ProcessInfo.processInfo.environment
        guard
            let token = env["SENTWISE_LIVE_CLERK_SESSION_TOKEN"], !token.isEmpty,
            let urlString = env["SENTWISE_INFERENCE_URL"], let baseURL = URL(string: urlString)
        else {
            throw XCTSkip("Set SENTWISE_LIVE_CLERK_SESSION_TOKEN and SENTWISE_INFERENCE_URL to run live tests.")
        }
        return (token, baseURL)
    }

    func testLiveMeReturnsAccountAndTrial() async throws {
        let (token, baseURL) = try liveConfig()
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertEqual(status, 200, "unexpected /v1/me status; body: \(String(decoding: data, as: UTF8.self))")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["userId"] as? String)
        XCTAssertNotNil(object["trial"] as? [String: Any])
    }

    func testLiveDraftReturnsText() async throws {
        let (token, baseURL) = try liveConfig()
        let client = ManagedInferenceClient(
            sessionProvider: EnvSessionProvider(token: token),
            transport: URLSessionTransport(),
            endpoint: baseURL.appendingPathComponent("v1/draft")
        )

        let response = try await client.complete(LLMRequest(
            system: "Reply with a single friendly word.",
            messages: [LLMMessage(role: .user, content: "Say hello.")],
            model: "claude-sonnet-4-6",
            maxTokens: 64,
            temperature: 0
        ))

        XCTAssertFalse(response.text.isEmpty, "live draft returned empty text")
    }
}
