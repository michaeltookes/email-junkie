import XCTest
@testable import Sentwise

/// Unit tests for `ManagedAccountService`'s Google (OAuth) sign-in (item 59),
/// driven end to end against the shared fake Clerk transport.
final class ManagedAccountServiceOAuthTests: XCTestCase {

    private func makeClerk(_ transport: QueueClerkTransport) -> ClerkClient {
        ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
    }

    private let startResponse =
        #"{"response":{"id":"sia_1","first_factor_verification":"#
            + #"{"external_verification_redirect_url":"https://accounts.google.com/o/oauth2/auth?x=1"}}}"#

    func testStartGoogleSignInReturnsURLAndPersistsClientToken() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        let url = try await service.startGoogleSignIn(redirectURL: "sentwise://oauth-callback")

        XCTAssertEqual(url.absoluteString, "https://accounts.google.com/o/oauth2/auth?x=1")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_A")
    }

    func testCompleteGoogleSignInStoresSessionAndReturnsIdentifier() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(startResponse, clientToken: "client_A"),
            clerkReply(
                #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1","identifier":"marcus@example.com"}}"#,
                clientToken: "client_B"
            ),
            clerkReply(#"{"jwt":"jwt.value"}"#, clientToken: "client_C")
        ])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        _ = try await service.startGoogleSignIn(redirectURL: "sentwise://oauth-callback")
        let email = try await service.completeGoogleSignIn(rotatingTokenNonce: "nonce_1")

        XCTAssertEqual(email, "marcus@example.com")
        let signedIn = await service.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
    }

    func testCompleteGoogleSignInWithoutStartThrows() async {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        do {
            _ = try await service.completeGoogleSignIn(rotatingTokenNonce: "nonce")
            XCTFail("Expected malformedResponse")
        } catch ClerkError.malformedResponse(let message, _) {
            XCTAssertEqual(message, "no oauth sign-in in progress")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
