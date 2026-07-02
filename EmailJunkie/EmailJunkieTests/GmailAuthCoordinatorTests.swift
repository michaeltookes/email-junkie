import XCTest
@testable import EmailJunkie

@MainActor
final class GmailAuthCoordinatorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let state = "FIXED-STATE"

    private func makeCoordinator(
        redirect: [String: String],
        tokenJSON: String,
        tokenStatus: Int = 200,
        seedCredentials: Bool = true,
        seedToken: OAuthToken? = nil
    ) -> (GmailAuthCoordinator, GmailAuthStore, SpyBrowser, FakeRedirectListener) {
        let secrets = InMemorySecretStore()
        let store = GmailAuthStore(secrets: secrets)
        if seedCredentials {
            try? store.saveCredentials(GmailCredentials(clientID: "cid", clientSecret: "secret"))
        }
        if let seedToken {
            try? store.saveToken(seedToken)
        }
        let transport = FakeTransport(
            response: HTTPResponse(statusCode: tokenStatus, body: Data(tokenJSON.utf8))
        )
        let listener = FakeRedirectListener(redirectURI: "http://127.0.0.1:9999/callback", params: redirect)
        let browser = SpyBrowser()
        let coordinator = GmailAuthCoordinator(
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { listener },
            browser: browser,
            now: { self.now },
            makeState: { self.state }
        )
        return (coordinator, store, browser, listener)
    }

    private func token(expiresAt: Date, refreshToken: String? = "rt") -> OAuthToken {
        OAuthToken(accessToken: "stored-at", refreshToken: refreshToken,
                   expiresAt: expiresAt, scope: "s", tokenType: "Bearer")
    }

    func testConnectHappyPathStoresTokenAndOpensBrowser() async throws {
        let (coordinator, store, browser, listener) = makeCoordinator(
            redirect: ["code": "auth-code", "state": state],
            tokenJSON: #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer","scope":"s"}"#
        )

        let result = try await coordinator.connect()

        XCTAssertEqual(result.accessToken, "at")
        XCTAssertTrue(store.isConnected)
        XCTAssertTrue(listener.stopped, "listener is always stopped")

        let opened = try XCTUnwrap(browser.openedURL)
        let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let byName = items.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(byName["client_id"], "cid")
        XCTAssertEqual(byName["redirect_uri"], "http://127.0.0.1:9999/callback")
        XCTAssertEqual(byName["state"], state)
    }

    func testConnectWithoutCredentialsThrows() async {
        let (coordinator, _, _, _) = makeCoordinator(
            redirect: ["code": "c", "state": state], tokenJSON: "{}", seedCredentials: false
        )
        await assertThrows(try await coordinator.connect(), GmailAuthError.missingCredentials)
    }

    func testConnectRejectsStateMismatch() async {
        let (coordinator, _, _, _) = makeCoordinator(
            redirect: ["code": "c", "state": "WRONG"], tokenJSON: "{}"
        )
        await assertThrows(try await coordinator.connect(), OAuthError.stateMismatch)
    }

    func testConnectSurfacesAuthorizationDenied() async {
        let (coordinator, _, _, _) = makeCoordinator(
            redirect: ["error": "access_denied", "state": state], tokenJSON: "{}"
        )
        await assertThrows(try await coordinator.connect(), OAuthError.authorizationDenied("access_denied"))
    }

    func testValidAccessTokenReturnsStoredWhenNotExpired() async throws {
        let (coordinator, _, _, _) = makeCoordinator(
            redirect: [:], tokenJSON: "{}",
            seedToken: token(expiresAt: now.addingTimeInterval(3600))
        )
        let access = try await coordinator.validAccessToken()
        XCTAssertEqual(access, "stored-at")
    }

    func testValidAccessTokenRefreshesWhenExpired() async throws {
        let (coordinator, store, _, _) = makeCoordinator(
            redirect: [:],
            tokenJSON: #"{"access_token":"fresh-at","expires_in":3600,"token_type":"Bearer","scope":"s"}"#,
            seedToken: token(expiresAt: now.addingTimeInterval(-10))
        )
        let access = try await coordinator.validAccessToken()
        XCTAssertEqual(access, "fresh-at")
        XCTAssertEqual(try store.loadToken()?.accessToken, "fresh-at")
        XCTAssertEqual(try store.loadToken()?.refreshToken, "rt", "refresh token carried forward")
    }

    func testDisconnectClearsTokenButKeepsCredentials() async throws {
        let (coordinator, store, _, _) = makeCoordinator(
            redirect: [:], tokenJSON: "{}",
            seedToken: token(expiresAt: now.addingTimeInterval(3600))
        )
        try coordinator.disconnect()
        XCTAssertFalse(store.isConnected)
        XCTAssertNotNil(try store.loadCredentials())
    }

    // MARK: - Helpers

    private func assertThrows<E: Error & Equatable>(
        _ expression: @autoclosure () async throws -> some Any,
        _ expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }
}

// MARK: - Fakes

final class FakeRedirectListener: RedirectListener {
    private let redirectURI: String
    private let params: [String: String]
    private(set) var stopped = false

    init(redirectURI: String, params: [String: String]) {
        self.redirectURI = redirectURI
        self.params = params
    }

    func start() async throws -> String { redirectURI }
    func waitForRedirect() async throws -> [String: String] { params }
    func stop() { stopped = true }
}

final class SpyBrowser: BrowserOpening {
    private(set) var openedURL: URL?
    func open(_ url: URL) { openedURL = url }
}
