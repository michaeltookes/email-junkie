import CryptoKit
import Foundation
import Security

/// A PKCE (Proof Key for Code Exchange, RFC 7636) verifier/challenge pair.
struct PKCE: Equatable {
    let verifier: String
    let challenge: String
    let method = "S256"
}

/// Generates PKCE pairs and derives challenges.
enum PKCEGenerator {
    /// Generates a fresh verifier and its S256 challenge.
    static func generate() -> PKCE {
        let verifier = randomURLSafeString(byteCount: 32)
        return PKCE(verifier: verifier, challenge: codeChallenge(for: verifier))
    }

    /// Derives the S256 code challenge for a given verifier.
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    /// A cryptographically random, URL-safe string (base64url, no padding).
    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // Fall back to a UUID-derived value; still adequately unpredictable.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64URLEncodedString()
    }
}
