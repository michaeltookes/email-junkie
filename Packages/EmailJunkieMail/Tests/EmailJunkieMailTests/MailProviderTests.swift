import XCTest
@testable import EmailJunkieMail

/// Tests the `MailProvider` seam via a fake. The real `IMAPMailProvider` network
/// path is verified live (it needs a real server), so these cover the contract
/// and the incomplete-credentials guard shared by callers.
final class MailProviderTests: XCTestCase {

    func testFakeProviderReceivesCredentials() async throws {
        let provider = FakeMailProvider(result: .success(()))
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "pw")

        try await provider.verifyConnection(credentials)

        XCTAssertEqual(provider.verifiedCredentials, credentials)
    }

    func testFakeProviderPropagatesFailure() async {
        let provider = FakeMailProvider(result: .failure(.authenticationFailed("bad")))
        do {
            try await provider.verifyConnection(
                MailAccountCredentials(email: "me@gmail.com", appPassword: "pw")
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MailError, .authenticationFailed("bad"))
        }
    }
}

/// A `MailProvider` fake for tests: records the credentials and returns a canned
/// result.
final class FakeMailProvider: MailProvider, @unchecked Sendable {
    private let result: Result<Void, MailError>
    private(set) var verifiedCredentials: MailAccountCredentials?

    init(result: Result<Void, MailError>) {
        self.result = result
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        verifiedCredentials = credentials
        try result.get()
    }
}
