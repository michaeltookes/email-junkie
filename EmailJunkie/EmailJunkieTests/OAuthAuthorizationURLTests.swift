import XCTest
@testable import EmailJunkie

final class OAuthAuthorizationURLTests: XCTestCase {

    private func queryItems(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return (components?.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    func testURLTargetsGoogleAuthorizationEndpoint() {
        let url = OAuthAuthorizationURL.make(
            clientID: "cid",
            redirectURI: "http://127.0.0.1:5000/callback",
            scopes: GoogleOAuth.scopes,
            pkce: PKCE(verifier: "v", challenge: "chal"),
            state: "state123"
        )
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
    }

    func testURLCarriesPKCEStateAndOfflineAccess() {
        let url = OAuthAuthorizationURL.make(
            clientID: "cid",
            redirectURI: "http://127.0.0.1:5000/callback",
            scopes: ["scope.a", "scope.b"],
            pkce: PKCE(verifier: "verifier", challenge: "challenge-value"),
            state: "state123"
        )
        let items = queryItems(of: url)
        XCTAssertEqual(items["client_id"], "cid")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:5000/callback")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "scope.a scope.b")
        XCTAssertEqual(items["code_challenge"], "challenge-value")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state123")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
    }

    func testLoginHintIncludedOnlyWhenProvided() {
        let pkce = PKCE(verifier: "v", challenge: "c")
        let without = OAuthAuthorizationURL.make(
            clientID: "cid", redirectURI: "uri", scopes: [], pkce: pkce, state: "s"
        )
        XCTAssertNil(queryItems(of: without)["login_hint"])

        let with = OAuthAuthorizationURL.make(
            clientID: "cid", redirectURI: "uri", scopes: [], pkce: pkce, state: "s",
            loginHint: "user@example.com"
        )
        XCTAssertEqual(queryItems(of: with)["login_hint"], "user@example.com")
    }
}
