import XCTest
@testable import Sentwise

/// A fake `ClerkHTTPTransport` for driving `ManagedAccountService` end to end.
private final class QueueClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private var responses: [ClerkHTTPResponse]
    private(set) var callCount = 0

    init(_ responses: [ClerkHTTPResponse]) { self.responses = responses }

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        callCount += 1
        guard !responses.isEmpty else { return ClerkHTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        return responses.removeFirst()
    }
}

private func response(_ json: String, status: Int = 200, clientToken: String? = nil) -> ClerkHTTPResponse {
    var headers: [String: String] = [:]
    if let clientToken { headers["authorization"] = "Bearer \(clientToken)" }
    return ClerkHTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
}

final class ManagedAccountServiceTests: XCTestCase {

    private func service(_ transport: QueueClerkTransport, secrets: SecretStore) -> ManagedAccountService {
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        return ManagedAccountService(secrets: secrets, clerk: clerk)
    }

    func testNotSignedInThrowsWhenMintingToken() async {
        let account = service(QueueClerkTransport([]), secrets: InMemorySecretStore())
        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFullSignInStoresCredentialsAndMintsToken() async throws {
        let secrets = InMemorySecretStore()
        // Full flow, in order:
        //   startSignIn:    create -> prepare
        //   completeSignIn: attempt -> tokens (completeSignIn verifies by minting once)
        //   currentSessionToken: tokens (a second, fresh mint)
        let transport = QueueClerkTransport([
            response(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            response(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            response(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_C"),
            response(#"{"jwt":"first.jwt"}"#, clientToken: "client_D"),
            response(#"{"jwt":"second.jwt"}"#, clientToken: "client_E")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        try await account.completeSignIn(code: "123456")

        let signedIn = await account.isSignedIn
        XCTAssertTrue(signedIn)
        // Device token + session id persisted; the latest rotated token is stored.
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")

        // A subsequent token mint returns a fresh jwt and rotates the device token.
        let token = try await account.currentSessionToken()
        XCTAssertEqual(token, "second.jwt")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_E")
    }

    func testSignOutClearsStoredCredentials() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(QueueClerkTransport([]), secrets: secrets)

        await account.signOut()

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }
}
