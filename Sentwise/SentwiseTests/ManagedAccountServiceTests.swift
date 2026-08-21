import XCTest
@testable import Sentwise

/// A fake `ClerkHTTPTransport` for driving `ManagedAccountService` end to end.
private final class QueueClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private var responses: [ClerkHTTPResponse]
    private(set) var callCount = 0
    private(set) var requests: [(url: URL, headers: [String: String], form: [String: String])] = []

    init(_ responses: [ClerkHTTPResponse]) { self.responses = responses }

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        callCount += 1
        requests.append((url, headers, form))
        guard !responses.isEmpty else { return ClerkHTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        return responses.removeFirst()
    }
}

private final class SuspendedClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ClerkHTTPResponse, Never>?
    var onRequest: (() -> Void)?

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let onRequest = self.onRequest
            lock.unlock()
            onRequest?()
        }
    }

    func resume(with response: ClerkHTTPResponse) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }
}

private final class MultiSuspendedClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<ClerkHTTPResponse, Never>] = []
    private var recordedRequests: [(url: URL, headers: [String: String], form: [String: String])] = []
    var onRequest: ((Int) -> Void)?

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        await withCheckedContinuation { continuation in
            let requestNumber: Int
            let onRequest: ((Int) -> Void)?
            lock.lock()
            recordedRequests.append((url, headers, form))
            continuations.append(continuation)
            requestNumber = recordedRequests.count
            onRequest = self.onRequest
            lock.unlock()
            onRequest?(requestNumber)
        }
    }

    func resumeNext(with response: ClerkHTTPResponse) {
        lock.lock()
        let continuation = continuations.isEmpty ? nil : continuations.removeFirst()
        lock.unlock()
        continuation?.resume(returning: response)
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    func authorizationHeader(at index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard recordedRequests.indices.contains(index) else { return nil }
        return recordedRequests[index].headers["authorization"]
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

    private func service(_ transport: ClerkHTTPTransport, secrets: SecretStore) -> ManagedAccountService {
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

    func testStartSignInPersistsCreatedTokenWhenPrepareFails() async throws {
        let secrets = InMemorySecretStore()
        let startedResponse = #"{"response":{"id":"sia_1","supported_first_factors":["#
            + #"{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
        let transport = QueueClerkTransport([
            response(startedResponse, clientToken: "client_A"),
            response(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503),
            response(startedResponse, clientToken: "client_B"),
            response(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_C")
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected prepare failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_A")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_A")

        try await account.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_A")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
    }

    func testStartSignInPersistsRotatedTokenFromCreationFailure() async throws {
        let secrets = InMemorySecretStore()
        let startedResponse = #"{"response":{"id":"sia_1","supported_first_factors":["#
            + #"{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
        let transport = QueueClerkTransport([
            response(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503, clientToken: "client_A"),
            response(startedResponse, clientToken: "client_B"),
            response(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_C")
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected creation failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_A")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_A")

        try await account.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests[1].headers["authorization"], "Bearer client_A")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
    }

    func testStartSignInPersistsRotatedTokenFromFallbackSignUpCreationFailure() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            response(
                #"{"errors":[{"code":"form_identifier_not_found","message":"not found"}]}"#,
                status: 422,
                clientToken: "client_A"
            ),
            response(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503, clientToken: "client_B")
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected sign-up creation failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_B")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transport.requests[1].headers["authorization"], "Bearer client_A")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
    }

    func testStartSignInPersistsRotatedTokenFromPrepareFailure() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            response(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            response(
                #"{"errors":[{"message":"temporarily unavailable"}]}"#,
                status: 503,
                clientToken: "client_B"
            )
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected prepare failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_B")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
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
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")

        try await account.completeSignIn(code: "123456")

        XCTAssertTrue(await account.isSignedIn)
        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_B")
        XCTAssertEqual(transport.requests[3].headers["authorization"], "Bearer client_C")
        XCTAssertEqual(transport.requests[4].headers["authorization"], "Bearer client_D")
        XCTAssertEqual(transport.requests[5].headers["authorization"], "Bearer client_E")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_F")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testCompleteSignInRetriesWithMintedTokenAfterSuccessfulMintPersistenceFailure() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [:])
        secrets.failOnSetKeys = [.managedClientToken]
        let transport = QueueClerkTransport([
            response(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            response(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            response(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_C"),
            response(#"{"jwt":"first.jwt"}"#, clientToken: "client_D"),
            response(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_E"),
            response(#"{"jwt":"retry.jwt"}"#, clientToken: "client_F")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        do {
            try await account.completeSignIn(code: "123456")
            XCTFail("Expected client-token persistence failure")
        } catch ManagedAccountTestSecretError.setDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(try secrets.value(for: .managedSessionID))

        secrets.failOnSetKeys = []
        try await account.completeSignIn(code: "123456")

        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_B")
        XCTAssertEqual(transport.requests[3].headers["authorization"], "Bearer client_C")
        XCTAssertEqual(transport.requests[4].headers["authorization"], "Bearer client_D")
        XCTAssertEqual(transport.requests[5].headers["authorization"], "Bearer client_E")
        XCTAssertTrue(await account.isSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_F")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testCompleteSignInRetriesWithRotatedTokenAfterFailedOTPAttempt() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            response(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            response(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            response(#"{"errors":[{"message":"Code is invalid."}]}"#, status: 422, clientToken: "client_C"),
            response(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_D"),
            response(#"{"jwt":"retry.jwt"}"#, clientToken: "client_E")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        do {
            try await account.completeSignIn(code: "000000")
            XCTFail("Expected failed OTP attempt")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(clientToken, "client_C")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
        try await account.completeSignIn(code: "123456")

        XCTAssertTrue(await account.isSignedIn)
        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_B")
        XCTAssertEqual(transport.requests[3].headers["authorization"], "Bearer client_C")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_E")
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

    func testCurrentSessionTokenPersistsRotatedClientTokenFromNonAuthMintFailure() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([
                response(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503, clientToken: "client_Y")
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

        XCTAssertTrue(await account.isSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Y")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testCurrentSessionTokenPersistsRotatedClientTokenFromMalformedMintResponse() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([
                response(#"{"unexpected":"shape"}"#, clientToken: "client_Y")
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

        XCTAssertTrue(await account.isSignedIn)
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

        XCTAssertTrue(await account.isSignedIn)
        await account.invalidateSession()

        XCTAssertFalse(await account.isSignedIn)
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
            response(startedResponse, clientToken: "client_A"),
            response(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B")
        ])
        let account = service(transport, secrets: secrets)

        await account.invalidateSession()
        try await account.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests.first?.headers["authorization"], "Bearer ")
        XCTAssertFalse(await account.isSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
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
        XCTAssertFalse(await account.isSignedIn)

        transport.resume(with: response(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Y"))
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

        transport.resumeNext(with: response(#"{"jwt":"first.jwt"}"#, clientToken: "client_Y"))
        XCTAssertEqual(try await firstTask.value, "first.jwt")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Y")

        await fulfillment(of: [secondStarted], timeout: 1.0)
        XCTAssertEqual(transport.authorizationHeader(at: 1), "Bearer client_Y")

        transport.resumeNext(with: response(#"{"jwt":"second.jwt"}"#, clientToken: "client_Z"))
        XCTAssertEqual(try await secondTask.value, "second.jwt")
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

        XCTAssertTrue(await account.isSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }
}
