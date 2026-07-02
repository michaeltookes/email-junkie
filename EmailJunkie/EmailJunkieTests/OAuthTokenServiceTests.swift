import XCTest
@testable import EmailJunkie

final class OAuthTokenServiceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let credentials = GmailCredentials(clientID: "cid", clientSecret: "secret")

    private func service(_ response: HTTPResponse) -> (OAuthTokenService, FakeTransport) {
        let transport = FakeTransport(response: response)
        return (OAuthTokenService(transport: transport), transport)
    }

    private func json(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8))
    }

    func testExchangeParsesTokenAndComputesExpiry() async throws {
        let (service, transport) = service(json("""
        {"access_token":"at","refresh_token":"rt","expires_in":3599,
         "scope":"s","token_type":"Bearer"}
        """))

        let token = try await service.exchange(
            code: "auth-code",
            verifier: "verifier",
            credentials: credentials,
            redirectURI: "http://127.0.0.1:9000/cb",
            now: now
        )

        XCTAssertEqual(token.accessToken, "at")
        XCTAssertEqual(token.refreshToken, "rt")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3599))
        XCTAssertEqual(transport.lastURL, GoogleOAuth.tokenEndpoint)
        XCTAssertEqual(transport.lastFields["grant_type"], "authorization_code")
        XCTAssertEqual(transport.lastFields["code"], "auth-code")
        XCTAssertEqual(transport.lastFields["code_verifier"], "verifier")
        XCTAssertEqual(transport.lastFields["redirect_uri"], "http://127.0.0.1:9000/cb")
        XCTAssertEqual(transport.lastFields["client_secret"], "secret")
    }

    func testRefreshCarriesForwardExistingRefreshToken() async throws {
        // Google omits refresh_token on refresh responses.
        let (service, transport) = service(json("""
        {"access_token":"new-at","expires_in":3600,"scope":"s","token_type":"Bearer"}
        """))

        let token = try await service.refresh(
            refreshToken: "existing-rt",
            credentials: credentials,
            now: now
        )

        XCTAssertEqual(token.accessToken, "new-at")
        XCTAssertEqual(token.refreshToken, "existing-rt")
        XCTAssertEqual(transport.lastFields["grant_type"], "refresh_token")
        XCTAssertEqual(transport.lastFields["refresh_token"], "existing-rt")
    }

    func testServerErrorIsSurfaced() async {
        let (service, _) = service(json("""
        {"error":"invalid_grant","error_description":"Token has been expired or revoked."}
        """, status: 400))

        do {
            _ = try await service.refresh(refreshToken: "rt", credentials: credentials, now: now)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(
                error as? OAuthError,
                .server(code: "invalid_grant", description: "Token has been expired or revoked.")
            )
        }
    }

    func testMalformedSuccessBodyThrowsInvalidResponse() async {
        let (service, _) = service(json("{not json", status: 200))
        do {
            _ = try await service.exchange(
                code: "c", verifier: "v", credentials: credentials,
                redirectURI: "uri", now: now
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? OAuthError, .invalidResponse)
        }
    }
}

/// A fake `HTTPTransport` returning a canned response and recording the request.
final class FakeTransport: HTTPTransport {
    var response: HTTPResponse
    private(set) var lastURL: URL?
    private(set) var lastFields: [String: String] = [:]

    init(response: HTTPResponse) {
        self.response = response
    }

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        lastURL = url
        lastFields = fields
        return response
    }
}
