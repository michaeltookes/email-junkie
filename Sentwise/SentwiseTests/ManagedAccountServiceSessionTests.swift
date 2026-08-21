import XCTest
@testable import Sentwise

/// Session-token minting, invalidation, and sign-out behavior of `ManagedAccountService`.
final class ManagedAccountServiceSessionTests: XCTestCase {

    private func service(_ transport: ClerkHTTPTransport, secrets: SecretStore) -> ManagedAccountService {
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        return ManagedAccountService(secrets: secrets, clerk: clerk)
    }

    func testCurrentSessionTokenInvalidatesStoredCredentialsOnAuthFailure() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([clerkReply(#"{"errors":[{"message":"expired"}]}"#, status: 401)]),
            secrets: secrets
        )

        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let awaited5 = await account.isSignedIn
        XCTAssertFalse(awaited5)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testCurrentSessionTokenPersistsRotatedClientTokenFromNonAuthMintFailure() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([
                clerkReply(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503, clientToken: "client_Y")
            ]),
            secrets: secrets
        )

        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected transport error")
        } catch LLMError.transport {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let awaited6 = await account.isSignedIn
        XCTAssertTrue(awaited6)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Y")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testInvalidateSessionMarksAccountSignedOutWhenKeychainRemovalFails() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        let awaited7 = await account.isSignedIn
        XCTAssertTrue(awaited7)
        await account.invalidateSession()

        let awaited8 = await account.isSignedIn
        XCTAssertFalse(awaited8)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testStartSignInAfterInvalidationDoesNotEchoStaleStoredClientToken() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let startedResponse = #"{"response":{"id":"sia_1","supported_first_factors":["#
            + #"{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
        let transport = QueueClerkTransport([
            clerkReply(startedResponse, clientToken: "client_A"),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B")
        ])
        let account = service(transport, secrets: secrets)

        await account.invalidateSession()
        try await account.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests.first?.headers["authorization"], "Bearer ")
        let awaited9 = await account.isSignedIn
        XCTAssertFalse(awaited9)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
    }

    func testCurrentSessionTokenSurfacesRotatedClientTokenPersistenceFailure() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedClientToken]
        let account = service(
            QueueClerkTransport([clerkReply(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Y")]),
            secrets: secrets
        )

        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected client-token persistence failure")
        } catch ManagedAccountTestSecretError.setDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testCurrentSessionTokenDoesNotRestoreClientTokenAfterSignOutDuringMint() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let transport = SuspendedClerkTransport()
        let requestStarted = expectation(description: "mint request started")
        transport.onRequest = { requestStarted.fulfill() }
        let account = service(transport, secrets: secrets)

        let tokenTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [requestStarted], timeout: 1.0)
        try await account.signOut()
        let awaited10 = await account.isSignedIn
        XCTAssertFalse(awaited10)

        transport.resume(with: clerkReply(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Y"))
        do {
            _ = try await tokenTask.value
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testCurrentSessionTokenSerializesRotatingTokenMints() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let transport = MultiSuspendedClerkTransport()
        let firstStarted = expectation(description: "first mint request started")
        let secondStarted = expectation(description: "second mint request started")
        transport.onRequest = { requestNumber in
            if requestNumber == 1 {
                firstStarted.fulfill()
            } else if requestNumber == 2 {
                secondStarted.fulfill()
            }
        }
        let account = service(transport, secrets: secrets)

        let firstTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [firstStarted], timeout: 1.0)

        let secondTask = Task { try await account.currentSessionToken() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requestCount, 1)

        transport.resumeNext(with: clerkReply(#"{"jwt":"first.jwt"}"#, clientToken: "client_Y"))
        let awaited11 = try await firstTask.value
        XCTAssertEqual(awaited11, "first.jwt")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Y")

        await fulfillment(of: [secondStarted], timeout: 1.0)
        XCTAssertEqual(transport.authorizationHeader(at: 1), "Bearer client_Y")

        transport.resumeNext(with: clerkReply(#"{"jwt":"second.jwt"}"#, clientToken: "client_Z"))
        let awaited12 = try await secondTask.value
        XCTAssertEqual(awaited12, "second.jwt")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Z")
    }

    func testSignOutClearsStoredCredentials() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(QueueClerkTransport([]), secrets: secrets)

        try await account.signOut()

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testSignOutSurfacesKeychainRemovalFailures() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch ManagedAccountTestSecretError.removeDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let awaited13 = await account.isSignedIn
        XCTAssertTrue(awaited13)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testCurrentSessionTokenPersistsRotatedClientTokenFromMalformedMintResponse() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([
                clerkReply(#"{"unexpected":"shape"}"#, clientToken: "client_Y")
            ]),
            secrets: secrets
        )

        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected transport error")
        } catch LLMError.transport {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Y")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }
}
