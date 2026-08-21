import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedAccountService")

/// Orchestrates the managed-inference account (backlog 56a): the Clerk email-code
/// sign-in, secure storage of the device/session credentials, and on-demand
/// minting of the short-lived session tokens the `sentwise-service` proxy verifies.
///
/// An `actor` so it is safely `Sendable` and can be used as the
/// `ManagedSessionProviding` for `LLMService` from any isolation context, while
/// its mutable in-progress sign-in state stays serialized. `AppState` (main
/// actor) drives it via `await`.
actor ManagedAccountService: ManagedSessionProviding {
    private let secrets: SecretStore
    private let clerk: ClerkClient

    /// In-progress sign-in handle (transient — only valid between `startSignIn`
    /// and `completeSignIn`).
    private var pendingSignIn: ClerkSignInHandle?

    init(secrets: SecretStore, clerk: ClerkClient = ClerkClient()) {
        self.secrets = secrets
        self.clerk = clerk
    }

    // MARK: - Sign-in

    /// True when a device token and session id are both stored — i.e. the user
    /// has a usable managed account.
    var isSignedIn: Bool {
        storedClientToken != nil && storedSessionID != nil
    }

    /// Begins email-code sign-in and sends the OTP. The device (client) token is
    /// persisted immediately so a rotated token survives even if the user quits
    /// before entering the code.
    func startSignIn(email: String) async throws {
        let handle = try await clerk.sendEmailCode(email: email, clientToken: storedClientToken ?? "")
        pendingSignIn = handle
        // Persisting the rotated device token early is best-effort; a Keychain
        // failure here must not abort sign-in — the token is re-persisted on verify.
        do {
            try persistClientToken(handle.clientToken)
        } catch {
            logger.error("Failed to persist Clerk client token during sign-in: \(error.localizedDescription)")
        }
    }

    /// Completes sign-in with the OTP code. On success stores the session id and
    /// the latest device token, then verifies the credentials end-to-end by
    /// minting one session token.
    func completeSignIn(code: String) async throws {
        guard let pending = pendingSignIn else {
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        let verified = try await clerk.verifyEmailCode(
            signInId: pending.signInId,
            code: code,
            clientToken: pending.clientToken,
            flow: pending.flow
        )

        // Prove the credentials can mint a token before storing the session.
        let minted = try await mintSessionToken(sessionID: verified.sessionId, clientToken: verified.clientToken)
        try persistClientToken(minted.clientToken)
        try persistSessionID(verified.sessionId)
        pendingSignIn = nil
    }

    /// Signs out: clears the stored device token and session id. Local mail data
    /// is untouched.
    func signOut() throws {
        pendingSignIn = nil
        var firstError: Error?
        do {
            try secrets.remove(.managedClientToken)
        } catch {
            firstError = error
        }
        do {
            try secrets.remove(.managedSessionID)
        } catch {
            firstError = firstError ?? error
        }
        if let firstError {
            throw firstError
        }
    }

    // MARK: - ManagedSessionProviding

    /// Mints a fresh, short-lived session JWT for the proxy. Rotates and re-stores
    /// the device token that Clerk returns. Throws `LLMError.managedNotSignedIn`
    /// when there is no stored account.
    func currentSessionToken() async throws -> String {
        guard let clientToken = storedClientToken, let sessionID = storedSessionID else {
            throw LLMError.managedNotSignedIn
        }
        do {
            let minted = try await mintSessionToken(sessionID: sessionID, clientToken: clientToken)
            try? persistClientToken(minted.clientToken)
            return minted.jwt
        } catch LLMError.managedNotSignedIn {
            // Device token or session no longer valid — force a fresh sign-in.
            try signOut()
            throw LLMError.managedNotSignedIn
        }
    }

    // MARK: - Storage

    private var storedClientToken: String? {
        let value = (try? secrets.value(for: .managedClientToken)) ?? nil
        return (value?.isEmpty == false) ? value : nil
    }

    private var storedSessionID: String? {
        let value = (try? secrets.value(for: .managedSessionID)) ?? nil
        return (value?.isEmpty == false) ? value : nil
    }

    private func persistClientToken(_ token: String) throws {
        guard !token.isEmpty else { return }
        try secrets.set(token, for: .managedClientToken)
    }

    private func persistSessionID(_ sessionID: String) throws {
        try secrets.set(sessionID, for: .managedSessionID)
    }

    private func mintSessionToken(sessionID: String, clientToken: String) async throws -> ClerkMintedToken {
        do {
            return try await clerk.mintSessionToken(sessionId: sessionID, clientToken: clientToken)
        } catch ClerkError.http(let status, _) where status == 401 || status == 404 {
            throw LLMError.managedNotSignedIn
        } catch let error as ClerkError {
            // Network/transport (or other non-auth) Clerk failure minting a token —
            // surface as a transport error so the user sees the "couldn't reach" message.
            throw LLMError.transport(String(describing: error))
        }
    }
}
