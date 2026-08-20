import XCTest
@testable import Sentwise

/// A fake `ClerkHTTPTransport` returning a preset queue of responses and
/// recording every request (URL, headers, form).
private final class FakeClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private var responses: [ClerkHTTPResponse]
    private(set) var requests: [(url: URL, headers: [String: String], form: [String: String])] = []

    init(_ responses: [ClerkHTTPResponse]) {
        self.responses = responses
    }

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        requests.append((url, headers, form))
        guard !responses.isEmpty else {
            return ClerkHTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        return responses.removeFirst()
    }
}

private func clerkResponse(
    _ json: String,
    status: Int = 200,
    clientToken: String? = nil
) -> ClerkHTTPResponse {
    var headers: [String: String] = [:]
    if let clientToken { headers["authorization"] = "Bearer \(clientToken)" }
    return ClerkHTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
}

final class ClerkClientTests: XCTestCase {

    private func client(_ transport: FakeClerkTransport) -> ClerkClient {
        ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
    }

    func testSendEmailCodeCreatesAndPreparesFirstFactor() async throws {
        let transport = FakeClerkTransport([
            clerkResponse(
                #"{"response":{"id":"sia_1","status":"needs_first_factor","#
                    + #""supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_9"}]}}"#,
                clientToken: "client_A"
            ),
            clerkResponse(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B")
        ])

        let handle = try await client(transport).sendEmailCode(email: "marcus@example.com", clientToken: "")

        XCTAssertEqual(handle.signInId, "sia_1")
        XCTAssertEqual(handle.emailAddressId, "ema_9")
        XCTAssertEqual(handle.clientToken, "client_B", "rotated client token is carried forward")

        // First request: empty Authorization, identifier form field, native marker.
        let create = transport.requests[0]
        XCTAssertTrue(create.url.absoluteString.contains("/v1/client/sign_ins"))
        XCTAssertTrue(create.url.absoluteString.contains("_is_native=1"))
        XCTAssertEqual(create.headers["authorization"], "Bearer ")
        XCTAssertEqual(create.form["identifier"], "marcus@example.com")

        // Second request: prepare_first_factor with the rotated token from step 1.
        let prepare = transport.requests[1]
        XCTAssertTrue(prepare.url.absoluteString.contains("/v1/client/sign_ins/sia_1/prepare_first_factor"))
        XCTAssertEqual(prepare.headers["authorization"], "Bearer client_A")
        XCTAssertEqual(prepare.form["strategy"], "email_code")
        XCTAssertEqual(prepare.form["email_address_id"], "ema_9")
    }

    func testSendEmailCodeThrowsWhenEmailCodeUnsupported() async {
        let transport = FakeClerkTransport([
            clerkResponse(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"password"}]}}"#,
                clientToken: "client_A"
            )
        ])
        do {
            _ = try await client(transport).sendEmailCode(email: "x@example.com", clientToken: "")
            XCTFail("Expected emailCodeUnsupported")
        } catch ClerkError.emailCodeUnsupported {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSendEmailCodeSurfacesServerErrorMessage() async {
        let transport = FakeClerkTransport([
            clerkResponse(
                #"{"errors":[{"message":"is invalid","long_message":"Email address is invalid."}]}"#,
                status: 422
            )
        ])
        do {
            _ = try await client(transport).sendEmailCode(email: "bad", clientToken: "")
            XCTFail("Expected http error")
        } catch ClerkError.http(let status, let message) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(message, "Email address is invalid.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testVerifyEmailCodeReturnsSessionOnComplete() async throws {
        let transport = FakeClerkTransport([
            clerkResponse(
                #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_7"}}"#,
                clientToken: "client_C"
            )
        ])

        let verified = try await client(transport).verifyEmailCode(
            signInId: "sia_1", code: "424242", clientToken: "client_B"
        )

        XCTAssertEqual(verified.sessionId, "sess_7")
        XCTAssertEqual(verified.clientToken, "client_C")
        let attempt = transport.requests[0]
        XCTAssertTrue(attempt.url.absoluteString.contains("/v1/client/sign_ins/sia_1/attempt_first_factor"))
        XCTAssertEqual(attempt.form["strategy"], "email_code")
        XCTAssertEqual(attempt.form["code"], "424242")
    }

    func testVerifyEmailCodeThrowsWhenNotComplete() async {
        let transport = FakeClerkTransport([
            clerkResponse(#"{"response":{"id":"sia_1","status":"needs_second_factor"}}"#, clientToken: "client_C")
        ])
        do {
            _ = try await client(transport).verifyEmailCode(signInId: "sia_1", code: "000000", clientToken: "client_B")
            XCTFail("Expected notComplete")
        } catch ClerkError.notComplete(let status) {
            XCTAssertEqual(status, "needs_second_factor")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMintSessionTokenReturnsJWTAndRotatesClientToken() async throws {
        let transport = FakeClerkTransport([
            clerkResponse(#"{"jwt":"session.jwt.value"}"#, clientToken: "client_D")
        ])

        let minted = try await client(transport).mintSessionToken(sessionId: "sess_7", clientToken: "client_C")

        XCTAssertEqual(minted.jwt, "session.jwt.value")
        XCTAssertEqual(minted.clientToken, "client_D")
        let tokenRequest = transport.requests[0]
        XCTAssertTrue(tokenRequest.url.absoluteString.contains("/v1/client/sessions/sess_7/tokens"))
        XCTAssertEqual(tokenRequest.headers["authorization"], "Bearer client_C")
    }
}
