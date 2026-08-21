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
    /// Changes whenever the stored account identity is cleared or replaced.
    private var authenticationGeneration = 0
    /// Set after the server rejects credentials that may still be present in
    /// Keychain. This keeps the current process logically signed out even if
    /// cleanup cannot remove every stale value.
    private var areStoredCredentialsInvalidated = false
    /// Clerk rotates the client token on every mint, so only one mint may be in
    /// flight at a time. Actor reentrancy alone is not enough because the actor is
    /// released while the network request is suspended.
    private var isMintingSessionToken = false
    private var mintWaiters: [CheckedContinuation<Void, Never>] = []

    init(secrets: SecretStore, clerk: ClerkClient = ClerkClient()) {
        self.secrets = secrets
        self.clerk = clerk
    }

    // MARK: - Sign-in

    /// True when a device token and session id are both stored — i.e. the user
    /// has a usable managed account.
    var isSignedIn: Bool {
        !areStoredCredentialsInvalidated && storedClientToken != nil && storedSessionID != nil
    }

    /// Begins email-code sign-in and sends the OTP. The device (client) token is
    /// persisted immediately so a rotated token survives even if the user quits
    /// before entering the code.
    func startSignIn(email: String) async throws {
        let existingClientToken = areStoredCredentialsInvalidated ? "" : storedClientToken ?? ""
        let created = try await clerk.createEmailCodeSignIn(email: email, clientToken: existingClientToken)
        persistClientTokenBestEffort(created.clientToken, context: "after creating sign-in")

        do {
            let prepared = try await clerk.prepareEmailCode(for: created)
            pendingSignIn = prepared
            persistClientTokenBestEffort(prepared.clientToken, context: "after preparing sign-in")
        } catch let error as ClerkError {
            persistClientTokenBestEffort(error.clientToken, context: "after failed sign-in prepare")
            throw error
        }
    }

    /// Completes sign-in with the OTP code. On success stores the session id and
    /// the latest device token, then verifies the credentials end-to-end by
    /// minting one session token.
    func completeSignIn(code: String) async throws {
        guard let pending = pendingSignIn else {
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        let verified: ClerkVerifiedSession
        do {
            verified = try await clerk.verifyEmailCode(
                signInId: pending.signInId,
                code: code,
                clientToken: pending.clientToken,
                flow: pending.flow
            )
        } catch let error as ClerkError {
            updatePendingSignIn(pending, clientToken: error.clientToken)
            throw error
        }

        updatePendingSignIn(pending, clientToken: verified.clientToken)
        // Prove the credentials can mint a token before storing the session.
        guard isPendingSignIn(pending) else {
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        let minted = try await mintSessionToken(
            sessionID: verified.sessionId,
            clientToken: verified.clientToken,
            preserveFailureClientToken: .pending(pending)
        )
        guard isPendingSignIn(pending) else {
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        try persistClientToken(minted.clientToken)
        try persistSessionID(verified.sessionId)
        areStoredCredentialsInvalidated = false
        authenticationGeneration &+= 1
        pendingSignIn = nil
    }

    /// Signs out: clears the stored device token and session id. Local mail data
    /// is untouched.
    func signOut() throws {
        let wasSignedIn = isSignedIn
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
        if wasSignedIn && !isSignedIn {
            authenticationGeneration &+= 1
        }
        if !hasStoredManagedCredential {
            areStoredCredentialsInvalidated = false
        }
        if let firstError {
            throw firstError
        }
    }

    // MARK: - ManagedSessionProviding

    /// Mints a fresh, short-lived session JWT for the proxy. Rotates and re-stores
    /// the device token that Clerk returns, surfacing persistence failures so the
    /// rotated token is never silently lost. Throws `LLMError.managedNotSignedIn`
    /// when there is no stored account.
    func currentSessionToken() async throws -> String {
        await beginMintTurn()
        defer { endMintTurn() }
        return try await mintCurrentSessionToken()
    }

    func invalidateSession() async {
        let wasSignedIn = isSignedIn
        pendingSignIn = nil
        areStoredCredentialsInvalidated = true
        if wasSignedIn {
            authenticationGeneration &+= 1
        }
        do {
            try secrets.remove(.managedClientToken)
        } catch {
            logger.error("Failed to remove invalid managed client token: \(error.localizedDescription)")
        }
        do {
            try secrets.remove(.managedSessionID)
        } catch {
            logger.error("Failed to remove invalid managed session id: \(error.localizedDescription)")
        }
    }

    private func mintCurrentSessionToken() async throws -> String {
        while true {
            guard !areStoredCredentialsInvalidated,
                  let clientToken = storedClientToken,
                  let sessionID = storedSessionID
            else {
                throw LLMError.managedNotSignedIn
            }
            let generation = authenticationGeneration
            do {
                let minted = try await mintSessionToken(
                    sessionID: sessionID,
                    clientToken: clientToken,
                    preserveFailureClientToken: .stored(generation: generation)
                )
                switch credentialState(generation: generation, sessionID: sessionID, clientToken: clientToken) {
                case .current:
                    try persistClientToken(minted.clientToken)
                    return minted.jwt
                case .rotated:
                    continue
                case .signedOutOrReplaced:
                    throw LLMError.managedNotSignedIn
                }
            } catch LLMError.managedNotSignedIn {
                switch credentialState(generation: generation, sessionID: sessionID, clientToken: clientToken) {
                case .current:
                    // Device token or session no longer valid — force a fresh sign-in.
                    await invalidateSession()
                    throw LLMError.managedNotSignedIn
                case .rotated:
                    continue
                case .signedOutOrReplaced:
                    throw LLMError.managedNotSignedIn
                }
            }
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

    private var hasStoredManagedCredential: Bool {
        storedClientToken != nil || storedSessionID != nil
    }

    private func persistClientToken(_ token: String) throws {
        guard !token.isEmpty else { return }
        try secrets.set(token, for: .managedClientToken)
    }

    private func persistClientTokenBestEffort(_ token: String?, context: String) {
        guard let token, !token.isEmpty else { return }
        do {
            try persistClientToken(token)
        } catch {
            logger.error("Failed to persist Clerk client token \(context): \(error.localizedDescription)")
        }
    }

    private func persistSessionID(_ sessionID: String) throws {
        try secrets.set(sessionID, for: .managedSessionID)
    }

    private func isPendingSignIn(_ handle: ClerkSignInHandle) -> Bool {
        pendingSignIn?.signInId == handle.signInId && pendingSignIn?.flow == handle.flow
    }

    private func updatePendingSignIn(_ handle: ClerkSignInHandle, clientToken: String?) {
        guard let clientToken, !clientToken.isEmpty, isPendingSignIn(handle) else { return }
        pendingSignIn = ClerkSignInHandle(
            signInId: handle.signInId,
            emailAddressId: handle.emailAddressId,
            clientToken: clientToken,
            flow: handle.flow
        )
        do {
            try persistClientToken(clientToken)
        } catch {
            logger.error("Failed to persist Clerk client token after sign-in attempt: \(error.localizedDescription)")
        }
    }

    private func beginMintTurn() async {
        guard isMintingSessionToken else {
            isMintingSessionToken = true
            return
        }
        await withCheckedContinuation { continuation in
            mintWaiters.append(continuation)
        }
    }

    private func endMintTurn() {
        guard !mintWaiters.isEmpty else {
            isMintingSessionToken = false
            return
        }
        let next = mintWaiters.removeFirst()
        next.resume()
    }

    private enum MintCredentialState {
        case current
        case rotated
        case signedOutOrReplaced
    }

    private enum MintFailureClientTokenHandling {
        case none
        case pending(ClerkSignInHandle)
        case stored(generation: Int)
    }

    private func credentialState(generation: Int, sessionID: String, clientToken: String) -> MintCredentialState {
        guard !areStoredCredentialsInvalidated,
              generation == authenticationGeneration,
              storedSessionID == sessionID
        else {
            return .signedOutOrReplaced
        }
        return storedClientToken == clientToken ? .current : .rotated
    }

    private func mintSessionToken(
        sessionID: String,
        clientToken: String,
        preserveFailureClientToken: MintFailureClientTokenHandling = .none
    ) async throws -> ClerkMintedToken {
        do {
            return try await clerk.mintSessionToken(sessionId: sessionID, clientToken: clientToken)
        } catch ClerkError.http(let status, _, _) where status == 401 || status == 404 {
            throw LLMError.managedNotSignedIn
        } catch let error as ClerkError {
            try preserveRotatedClientTokenFromMintFailure(
                error.clientToken,
                sessionID: sessionID,
                clientToken: clientToken,
                handling: preserveFailureClientToken
            )
            // Network/transport (or other non-auth) Clerk failure minting a token —
            // surface as a transport error so the user sees the "couldn't reach" message.
            throw LLMError.transport(String(describing: error))
        }
    }

    private func preserveRotatedClientTokenFromMintFailure(
        _ rotatedClientToken: String?,
        sessionID: String,
        clientToken: String,
        handling: MintFailureClientTokenHandling
    ) throws {
        guard let rotatedClientToken, !rotatedClientToken.isEmpty else { return }
        switch handling {
        case .none:
            return
        case .pending(let handle):
            updatePendingSignIn(handle, clientToken: rotatedClientToken)
        case .stored(let generation):
            guard credentialState(
                generation: generation,
                sessionID: sessionID,
                clientToken: clientToken
            ) == .current else {
                return
            }
            try persistClientToken(rotatedClientToken)
        }
    }
}
