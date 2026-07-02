import Foundation

/// Persists the Gmail OAuth session — the BYO client credentials and the token
/// set — in a `SecretStore` (the Keychain in production). Everything here is a
/// secret, so nothing is written to the plaintext settings file.
final class GmailAuthStore {

    private let secrets: SecretStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(secrets: SecretStore = KeychainStore.shared) {
        self.secrets = secrets
    }

    // MARK: - Credentials

    func saveCredentials(_ credentials: GmailCredentials) throws {
        try secrets.set(credentials.clientID, for: .googleClientID)
        try secrets.set(credentials.clientSecret, for: .googleClientSecret)
    }

    func loadCredentials() throws -> GmailCredentials? {
        guard let clientID = try secrets.value(for: .googleClientID),
              let clientSecret = try secrets.value(for: .googleClientSecret),
              !clientID.isEmpty, !clientSecret.isEmpty else {
            return nil
        }
        return GmailCredentials(clientID: clientID, clientSecret: clientSecret)
    }

    func deleteCredentials() throws {
        try secrets.remove(.googleClientID)
        try secrets.remove(.googleClientSecret)
    }

    // MARK: - Token

    func saveToken(_ token: OAuthToken) throws {
        let data = try encoder.encode(token)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OAuthError.invalidResponse
        }
        try secrets.set(json, for: .gmailToken)
    }

    func loadToken() throws -> OAuthToken? {
        guard let json = try secrets.value(for: .gmailToken),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(OAuthToken.self, from: data)
    }

    func deleteToken() throws {
        try secrets.remove(.gmailToken)
    }

    // MARK: - Convenience

    /// Whether a token is currently stored (i.e. an account is connected).
    var isConnected: Bool {
        let token = (try? loadToken()) ?? nil
        return token != nil
    }
}
