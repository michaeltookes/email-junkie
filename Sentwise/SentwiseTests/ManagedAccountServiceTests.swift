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

private enum ManagedAccountTestSecretError: Error {
    case setDenied
    case removeDenied
}

private final class ManagedAccountFailingSecretStore: SecretStore {
    var failOnSetKeys: Set<SecretKey> = []
    var failOnRemoveKeys: Set<SecretKey> = []
    private var storage: [String: String]

    init(seed: [SecretKey: String]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        if failOnSetKeys.contains(key) {
            throw ManagedAccountTestSecretError.setDenied
        }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        if failOnRemoveKeys.contains(key) {
            throw ManagedAccountTestSecretError.removeDenied
        }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
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

    func testCompleteSignInKeepsPendingAndDoesNotStoreSessionWhenMintFails() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            response(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            response(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            response(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_C"),
            response(#"{"errors":[{"message":"offline"}]}"#, status: 503, clientToken: "client_D"),
            response(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_E"),
            response(#"{"jwt":"retry.jwt"}"#, clientToken: "client_F")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        do {
            try await account.completeSignIn(code: "123456")
            XCTFail("Expected token mint failure")
        } catch LLMError.transport {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(await account.isSignedIn)
        XCTAssertNil(try secrets.value(for: .managedSessionID))

        try await account.completeSignIn(code: "123456")

        XCTAssertTrue(await account.isSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_F")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testCurrentSessionTokenInvalidatesStoredCredentialsOnAuthFailure() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([response(#"{"errors":[{"message":"expired"}]}"#, status: 401)]),
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

        XCTAssertFalse(await account.isSignedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testCurrentSessionTokenSurfacesRotatedClientTokenPersistenceFailure() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedClientToken]
        let account = service(
            QueueClerkTransport([response(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Y")]),
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

        XCTAssertTrue(await account.isSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }
}
