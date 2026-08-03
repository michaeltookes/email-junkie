import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "SavedAccounts")

/// Saved-accounts management (item 48): remembering multiple accounts, switching
/// between them without re-entry, and per-account Keychain secrets. Kept in its
/// own file so `AppState` stays within the file/type length limits.
extension AppState {

    // MARK: - Per-account secret access

    /// Reads the stored app password for `email`, preferring the per-account
    /// Keychain key and falling back to the legacy shared slot for installs that
    /// predate the migration (or test fixtures seeded on the legacy key). Never
    /// logs or returns the value anywhere user-visible.
    static func storedMailPassword(forEmail email: String, secrets: SecretStore) -> String? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines)
        // No active account means no password to read — never surface a stray
        // legacy secret when there is no email to attribute it to.
        guard !normalized.isEmpty else { return nil }

        if let perAccount = (try? secrets.value(for: .mailAppPassword(email: normalized))) ?? nil,
           !perAccount.isEmpty {
            return perAccount
        }
        // Legacy fallback: a pre-v11 install whose secret has not yet moved, or a
        // test fixture that seeded the old shared slot.
        if let legacy = (try? secrets.value(for: .mailAppPassword)) ?? nil, !legacy.isEmpty {
            return legacy
        }
        return nil
    }

    /// Instance convenience over `storedMailPassword(forEmail:secrets:)`.
    func storedMailPassword(forEmail email: String) -> String? {
        Self.storedMailPassword(forEmail: email, secrets: secrets)
    }

    // MARK: - v10 → v11 migration

    /// Migrates a pre-v11 settings file to the saved-accounts model: the existing
    /// single account becomes the first saved account, and its app password moves
    /// from the legacy shared Keychain slot to a per-account key (the legacy slot
    /// is then removed so no orphaned secret remains). Idempotent and safe to run
    /// on every launch — it no-ops once `schemaVersion` has reached v11.
    static func migratedSavedAccountsSettings(
        _ settings: Settings,
        secrets: SecretStore,
        persistence: PersistenceProvider
    ) -> Settings {
        guard settings.schemaVersion < Settings.savedAccountsSchemaVersion else { return settings }

        var migrated = settings
        let email = settings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        if !email.isEmpty {
            migrateLegacyMailSecret(forEmail: email, secrets: secrets)
            if !migrated.savedAccounts.contains(where: { $0.id == SavedMailAccount.normalizedEmail(email) }) {
                migrated.savedAccounts.insert(
                    SavedMailAccount(email: email, host: settings.mailHost, port: settings.mailPort),
                    at: 0
                )
            }
        }

        migrated.schemaVersion = Settings.currentSchemaVersion
        do {
            try persistence.saveSettingsSync(migrated)
        } catch {
            logger.error("Failed to persist saved-accounts migration: \(error.localizedDescription)")
        }
        return migrated
    }

    /// Moves the legacy shared app-password secret to the per-account key for
    /// `email`, then removes the legacy item. No-op when there is nothing to move.
    private static func migrateLegacyMailSecret(forEmail email: String, secrets: SecretStore) {
        guard let legacyPassword = (try? secrets.value(for: .mailAppPassword)) ?? nil,
              !legacyPassword.isEmpty else {
            return
        }
        let perAccountKey = SecretKey.mailAppPassword(email: email)
        let existing = (try? secrets.value(for: perAccountKey)) ?? nil
        do {
            if existing == nil || existing?.isEmpty == true {
                try secrets.set(legacyPassword, for: perAccountKey)
            }
            try secrets.remove(.mailAppPassword)
            logger.info("Migrated mail app password to a per-account Keychain key")
        } catch {
            logger.error("Failed to migrate legacy mail secret: \(error.localizedDescription)")
        }
    }

    // MARK: - Saved-account list mutation

    /// Inserts or updates the saved-account entry for these connection details.
    func upsertSavedAccount(email: String, host: String, port: Int) {
        let account = SavedMailAccount(email: email, host: host, port: port)
        guard !account.id.isEmpty else { return }
        if let index = savedAccounts.firstIndex(where: { $0.id == account.id }) {
            if savedAccounts[index] != account {
                savedAccounts[index] = account
            }
        } else {
            savedAccounts.append(account)
        }
    }

    /// Whether `account` is the one currently connected.
    func isActiveAccount(_ account: SavedMailAccount) -> Bool {
        isAccountConnected
            && SavedMailAccount.normalizedEmail(mailEmail) == account.id
    }

    // MARK: - Switching

    /// Switches to a previously saved account using its stored credentials, with
    /// no re-entry (item 48). Tears down the active account cleanly (stops
    /// watching, cancels outstanding send countdowns, clears account-scoped
    /// preview/browser/cleanup state) and connects the target through the normal
    /// verify path so the connection status stays honest. Both accounts' secrets
    /// are retained — only the *active* pointer moves. Pending drafts are left
    /// untouched; they stay scoped to their originating account by identity.
    func switchToSavedAccount(_ account: SavedMailAccount) async {
        guard !isActiveAccount(account) else { return }

        guard let password = storedMailPassword(forEmail: account.email), !password.isEmpty else {
            connectionError = "No saved password for \(account.email). Reconnect this account to continue."
            return
        }

        // Clean teardown of the outgoing account before adopting the new one.
        let wasWatching = watchStatus == .watching
        stopWatching()
        cancelAllSendCountdowns()

        mailEmail = account.email
        mailHost = account.host
        mailPort = account.port
        mailAppPassword = password
        markMailHostVerifiedForGuidance()

        await testConnection()

        if isAccountConnected, wasWatching {
            startWatchingIfReady()
        }
    }

    // MARK: - Removal

    /// Removes a saved account (item 48): deletes exactly that account's Keychain
    /// secret and drops it from the list. If it was the active account, the app
    /// goes offline and the account inputs are cleared. Other accounts' secrets
    /// are never touched.
    func removeSavedAccount(_ account: SavedMailAccount) {
        connectionError = nil
        let wasActive = isActiveAccount(account)

        do {
            try secrets.remove(.mailAppPassword(email: account.email))
            if wasActive {
                // Also clear any legacy shared slot so nothing is orphaned.
                try secrets.remove(.mailAppPassword)
            }
        } catch {
            connectionError = Self.keychainMessage(action: "remove", error: error)
            return
        }

        savedAccounts.removeAll { $0.id == account.id }

        if wasActive {
            goOfflineAfterRemovingActiveAccount()
        }

        do {
            try persistSettingsSync(buildSettings())
        } catch {
            connectionError = Self.settingsMessage(action: "save", error: error)
        }
        logger.info("Saved account removed")
    }

    /// Tears down the active account after it has been removed from the list.
    private func goOfflineAfterRemovingActiveAccount() {
        mailEmail = ""
        mailAppPassword = ""
        isAccountConnected = false
        cancelAllSendCountdowns()
        stopWatching()
        resetMessagePreviewForAccountChange()
    }
}
