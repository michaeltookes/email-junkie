import Foundation

/// Static Google OAuth / Gmail constants.
enum GoogleOAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Minimum scopes needed: read + modify messages (inbox and Sent), and send.
    /// `gmail.modify` already includes read access, so `gmail.readonly` is omitted
    /// as redundant.
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send"
    ]
}

/// The user-supplied Google Cloud OAuth client (BYO credentials).
struct GmailCredentials: Equatable {
    let clientID: String
    let clientSecret: String
}

/// An OAuth token set returned by Google's token endpoint.
struct OAuthToken: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    /// Absolute expiry time, computed from `expires_in` at fetch time.
    let expiresAt: Date
    let scope: String
    let tokenType: String

    /// Whether the access token is expired (or within `leeway` of expiring).
    func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

/// Errors surfaced by the OAuth flow.
enum OAuthError: Error, Equatable {
    /// The token endpoint returned an error (`error` / `error_description`).
    case server(code: String, description: String?)
    /// The response could not be decoded.
    case invalidResponse
    /// The `state` returned on the redirect did not match what we sent (CSRF guard).
    case stateMismatch
    /// The redirect carried an error instead of an authorization code.
    case authorizationDenied(String)
    /// No refresh token is available to refresh the session.
    case missingRefreshToken
}
