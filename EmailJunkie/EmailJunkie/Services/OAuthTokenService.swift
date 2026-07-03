import Foundation

/// Exchanges authorization codes for tokens and refreshes access tokens against
/// Google's token endpoint. Pure logic over an injectable `HTTPTransport`.
struct OAuthTokenService {
    let transport: HTTPTransport

    /// Exchanges an authorization code (with its PKCE verifier) for a token set.
    func exchange(
        code: String,
        verifier: String,
        credentials: GmailCredentials,
        redirectURI: String,
        now: Date
    ) async throws -> OAuthToken {
        let response = try await transport.postForm(GoogleOAuth.tokenEndpoint, fields: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "redirect_uri": redirectURI
        ])
        return try token(from: response, now: now, fallbackRefreshToken: nil)
    }

    /// Refreshes an access token using a refresh token. Google does not return a
    /// new refresh token on refresh, so the existing one is carried forward.
    func refresh(
        refreshToken: String,
        credentials: GmailCredentials,
        now: Date
    ) async throws -> OAuthToken {
        let response = try await transport.postForm(GoogleOAuth.tokenEndpoint, fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret
        ])
        return try token(from: response, now: now, fallbackRefreshToken: refreshToken)
    }

    // MARK: - Response parsing

    private func token(
        from response: HTTPResponse,
        now: Date,
        fallbackRefreshToken: String?
    ) throws -> OAuthToken {
        guard response.isSuccess else {
            if let error = try? JSONDecoder().decode(TokenErrorResponse.self, from: response.body) {
                throw OAuthError.server(code: error.error, description: error.errorDescription)
            }
            throw OAuthError.invalidResponse
        }

        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
            throw OAuthError.invalidResponse
        }

        return OAuthToken(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? fallbackRefreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(decoded.expiresIn)),
            scope: decoded.scope ?? "",
            tokenType: decoded.tokenType ?? "Bearer"
        )
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
        }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}
