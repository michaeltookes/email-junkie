import Foundation

/// Builds the Google OAuth authorization URL for the PKCE desktop/loopback flow.
enum OAuthAuthorizationURL {
    static func make(
        clientID: String,
        redirectURI: String,
        scopes: [String],
        pkce: PKCE,
        state: String,
        loginHint: String? = nil
    ) -> URL {
        var components = URLComponents(
            url: GoogleOAuth.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )!

        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            // Request a refresh token and force the consent screen so one is issued.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        if let loginHint {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }

        components.queryItems = items
        return components.url!
    }
}
