import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedAccount")

/// The stage of the managed-inference email-code sign-in flow.
enum ManagedSignInStage: Equatable {
    /// No sign-in in progress — show the email field.
    case idle
    /// A code was emailed — show the code field.
    case codeSent
}

/// Managed-inference account actions on `AppState` (backlog item 56a): the
/// email-code sign-in flow, sign-out, and the one-time settings migration onto
/// the managed provider. Kept in its own file so `AppState` stays within length
/// limits, mirroring `AppState+LLM`.
extension AppState {

    // MARK: - Sign-in flow

    /// Sends a one-time code to the email in `managedEmailInput` and advances the
    /// flow to the code-entry stage. Disabled in Prowl hunt mode.
    func startManagedSignIn() async {
        managedError = nil
        guard !ProwlHuntRuntime.current.isEnabled else {
            managedError = "Sign-in is disabled during Prowl hunts."
            return
        }
        let email = managedEmailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.count >= 3 else {
            managedError = "Enter your email address."
            return
        }

        isManagedBusy = true
        defer { isManagedBusy = false }
        pendingManagedSignInEmail = nil
        do {
            try await managedAccount.startSignIn(email: email)
            pendingManagedSignInEmail = email
            managedEmailInput = email
            managedSignInStage = .codeSent
        } catch {
            managedError = Self.managedMessage(for: error)
        }
    }

    /// Verifies the code in `managedCodeInput`, completing sign-in. On success the
    /// managed provider becomes the connected provider and drafting is enabled.
    func verifyManagedCode() async {
        managedError = nil
        let code = managedCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            managedError = "Enter the code from your email."
            return
        }

        isManagedBusy = true
        defer { isManagedBusy = false }
        do {
            try await managedAccount.completeSignIn(code: code)
        } catch {
            managedError = Self.managedMessage(for: error)
            return
        }

        // Sign-in succeeded: record the account tied to the pending Clerk flow.
        let signedInEmail = pendingManagedSignInEmail
            ?? managedEmailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        managedAccountEmail = signedInEmail
        managedEmailInput = signedInEmail
        managedCodeInput = ""
        pendingManagedSignInEmail = nil
        managedSignInStage = .idle
        isManagedSignedIn = true

        // Managed is now the active provider path; mark it verified so drafting
        // and the connected UI light up. The model is always the managed default.
        if llmProviderKind == .managed {
            verifiedLLMModel = llmProviderKind.defaultModel
            refreshLLMConnectionStatus()
            resetDraftPreviewForLLMChange()
        }
        saveSettings()
        startTranscriptFolderWatchingIfEnabled()
    }

    func resetManagedSignInFlow() {
        pendingManagedSignInEmail = nil
        managedSignInStage = .idle
        managedCodeInput = ""
        managedError = nil
    }

    /// Signs out of the managed account: clears stored tokens and connected state.
    /// Local mail data and voice profile are untouched.
    func signOutManaged() async {
        managedError = nil
        isManagedBusy = true
        defer { isManagedBusy = false }
        do {
            try await managedAccount.signOut()
        } catch {
            if await managedAccount.isSignedIn {
                managedError = Self.managedMessage(for: error)
                return
            }
            applyManagedSignedOutState(clearEmailInput: true)
            managedError = Self.managedMessage(for: error)
            saveSettings()
            return
        }
        applyManagedSignedOutState(clearEmailInput: true)
        saveSettings()
    }

    private func applyManagedSignedOutState(clearEmailInput: Bool) {
        isManagedSignedIn = false
        managedAccountEmail = ""
        if clearEmailInput {
            managedEmailInput = ""
        }
        managedCodeInput = ""
        pendingManagedSignInEmail = nil
        managedSignInStage = .idle
        if llmProviderKind == .managed {
            verifiedLLMModel = ""
            refreshLLMConnectionStatus()
            resetDraftPreviewForLLMChange()
        }
    }

    // MARK: - Error mapping

    static func managedMessage(for error: Error) -> String {
        switch error {
        case ClerkError.transport, LLMError.transport:
            return "Couldn't reach Sentwise sign-in. Check your connection and try again."
        case ClerkError.http(_, let message, _):
            return message ?? "Sign-in failed. Please try again."
        case ClerkError.notComplete(_, let missingFields, _) where !missingFields.isEmpty:
            return "Sign-up couldn't finish: the account service still requires "
                + missingFields.joined(separator: ", ")
                + ". This is a Sentwise configuration issue, not your code — please contact support."
        case ClerkError.notComplete:
            return "That code didn't complete sign-in. Request a new code and try again."
        case ClerkError.emailCodeUnsupported:
            return "This account can't sign in with an email code."
        case ClerkError.malformedResponse:
            return "Unexpected response from sign-in. Please try again."
        case LLMError.managedNotSignedIn:
            return "Sign-in didn't stick. Please try again."
        case KeychainError.unexpectedStatus(let status):
            return "Couldn't update Sentwise AI credentials in Keychain. Keychain returned status \(status)."
        case KeychainError.dataEncodingFailed:
            return "Couldn't update Sentwise AI credentials in Keychain."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Launch state (item 56a)

    /// What the LLM fields should look like at launch for the managed provider.
    /// When the account credentials are present, managed is treated as verified
    /// with its default model regardless of any stale custom model in settings.
    struct ManagedLaunchState: Equatable {
        let provider: LLMProviderKind
        let hasCredentials: Bool
        let restoreVerification: Bool
        let llmModel: String
        let verifiedLLMModel: String
    }

    static func managedLaunchState(settings: Settings, secrets: SecretStore) -> ManagedLaunchState {
        let provider = LLMProviderKind(rawValue: settings.llmProvider) ?? .anthropic
        let hasInvalidatedCredentials = secrets.hasValue(for: .managedCredentialsInvalidated)
        let hasCredentials = !hasInvalidatedCredentials
            && secrets.hasValue(for: .managedClientToken)
            && secrets.hasValue(for: .managedSessionID)
        let restore = provider == .managed && hasCredentials
        return ManagedLaunchState(
            provider: provider,
            hasCredentials: hasCredentials,
            restoreVerification: restore,
            llmModel: restore ? "" : settings.llmModel,
            verifiedLLMModel: restore ? provider.defaultModel : settings.llmVerifiedModel
        )
    }

    /// Writes the restored managed verification back to disk when launch changed
    /// what was loaded, so the next launch doesn't redo the restoration.
    func persistRestoredManagedVerificationIfNeeded(_ launch: ManagedLaunchState, loadedFrom settings: Settings) {
        guard launch.restoreVerification,
              settings.llmModel != launch.llmModel || settings.llmVerifiedModel != launch.verifiedLLMModel
        else { return }
        do {
            try persistSettingsSync(buildSettings())
        } catch {
            logger.error("Failed to persist restored managed verification: \(error.localizedDescription)")
        }
    }

    // MARK: - Migration (item 56a)

    /// Runs all launch-time settings migrations in order: the saved-accounts move
    /// (item 48) then the managed-inference default (item 56a). Keeps `AppState.init`
    /// short by chaining both here.
    static func fullyMigratedSettings(
        loaded: Settings,
        secrets: SecretStore,
        persistence: PersistenceProvider
    ) -> Settings {
        let accountsMigrated = migratedSavedAccountsSettings(
            loaded,
            secrets: secrets,
            persistence: persistence,
            targetSchemaVersion: Settings.managedInferenceSchemaVersion - 1,
            shouldPersist: false
        )
        return migratedManagedInferenceSettings(
            accountsMigrated,
            originalSchemaVersion: loaded.schemaVersion,
            secrets: secrets,
            persistence: persistence
        )
    }

    /// Moves an existing install with no configured BYO provider onto managed
    /// inference. A configured BYO user (a stored key or a verified model) keeps
    /// their provider. Runs once, gated on the original schema version.
    static func migratedManagedInferenceSettings(
        _ settings: Settings,
        originalSchemaVersion: Int,
        secrets: SecretStore,
        persistence: PersistenceProvider
    ) -> Settings {
        guard originalSchemaVersion < Settings.managedInferenceSchemaVersion else { return settings }
        var migrated = settings

        let provider = LLMProviderKind(rawValue: settings.llmProvider) ?? .anthropic
        if provider != .managed {
            let hasKey = secrets.hasValue(for: .llmAPIKey(provider: settings.llmProvider))
            let hasVerifiedModel = !settings.llmVerifiedModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isConfigured = hasKey || hasVerifiedModel
            if !isConfigured {
                migrated.llmProvider = "managed"
                migrated.llmModel = ""
            }
        }

        migrated.schemaVersion = Settings.currentSchemaVersion
        if migrated != settings {
            do {
                try persistence.saveSettingsSync(migrated)
            } catch {
                logger.error("Failed to persist managed-inference migration: \(error.localizedDescription)")
            }
        }
        return migrated
    }

    /// If the managed account actor invalidated stored credentials while minting a
    /// session token, mirror that state back into the published AppState flags.
    /// Returns `true` when this call signed the account out, so callers whose
    /// staleness guards would otherwise swallow the error can still surface it —
    /// the configuration changed *because of* this failure, not under the user.
    @discardableResult
    func reconcileManagedAccountState(after error: Error, provider: LLMProviderKind) async -> Bool {
        guard provider == .managed else { return false }
        guard case LLMError.managedNotSignedIn = error else { return false }
        guard !(await managedAccount.isSignedIn) else { return false }

        applyManagedSignedOutState(clearEmailInput: false)
        saveSettings()
        return true
    }
}
