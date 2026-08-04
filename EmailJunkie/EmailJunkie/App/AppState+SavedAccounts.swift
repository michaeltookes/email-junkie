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

    /// Removes the active account's password for disconnect. The legacy shared
    /// slot is removed only when the active account has no usable per-account key,
    /// because it may still back an older inactive account after a failed migration.
    func removeActiveMailPasswordForDisconnect() -> Bool {
        let activeEmail = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKey = activeEmail.isEmpty ? nil : SecretKey.mailAppPassword(email: activeEmail)
        let activeAccountPassword: String?
        let shouldRemoveLegacyPassword: Bool

        do {
            if let activeKey {
                activeAccountPassword = try secrets.value(for: activeKey)
            } else {
                activeAccountPassword = nil
            }
            if !activeEmail.isEmpty, activeAccountPassword?.isEmpty != false {
                let legacyPassword = try secrets.value(for: .mailAppPassword)
                shouldRemoveLegacyPassword = legacyPassword?.isEmpty == false
            } else {
                shouldRemoveLegacyPassword = false
            }
        } catch {
            connectionError = Self.keychainMessage(action: "read", error: error)
            return false
        }

        do {
            if shouldRemoveLegacyPassword {
                try secrets.remove(.mailAppPassword)
            }
            if let activeKey, activeAccountPassword != nil {
                try secrets.remove(activeKey)
            }
            return true
        } catch {
            connectionError = Self.keychainMessage(action: "remove", error: error)
            return false
        }
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

        let outgoingSettings = buildSettings()
        // Clean teardown of the outgoing account before adopting the new one.
        let wasWatching = watchStatus == .watching
        stopWatching()
        cancelAllSendCountdowns()

        mailEmail = account.email
        mailHost = account.host
        mailPort = account.port
        mailAppPassword = password
        isAccountConnected = false
        markMailHostVerifiedForGuidance()

        await testConnection()

        guard connectionError == nil, isAccountConnected, isActiveAccount(account) else {
            restoreConnectionSnapshot(settings: outgoingSettings)
            if wasWatching {
                startWatchingIfReady()
            }
            return
        }

        if wasWatching {
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
        let accountKey = SecretKey.mailAppPassword(email: account.email)
        let previousAccountPassword: String?
        let previousLegacyPassword: String?
        let shouldRemoveLegacyPassword: Bool

        do {
            previousAccountPassword = try secrets.value(for: accountKey)
            let hasUsableAccountPassword = previousAccountPassword?.isEmpty == false
            if !hasUsableAccountPassword {
                previousLegacyPassword = try secrets.value(for: .mailAppPassword)
            } else {
                previousLegacyPassword = nil
            }
            shouldRemoveLegacyPassword = !hasUsableAccountPassword && previousLegacyPassword?.isEmpty == false
        } catch {
            connectionError = Self.keychainMessage(action: "read", error: error)
            return
        }

        var nextSettings = buildSettings(mailEmail: wasActive ? "" : nil)
        nextSettings.savedAccounts.removeAll { $0.id == account.id }

        do {
            try secrets.remove(accountKey)
            if shouldRemoveLegacyPassword {
                // Also clear any legacy shared slot so nothing is orphaned.
                try secrets.remove(.mailAppPassword)
            }
        } catch {
            let rollbackError = restoreRemovedAccountSecrets(
                accountEmail: account.email,
                accountPassword: previousAccountPassword,
                legacyPassword: shouldRemoveLegacyPassword ? previousLegacyPassword : nil
            )
            var message = Self.keychainMessage(action: "remove", error: error)
            if let rollbackError {
                message += " " + Self.keychainMessage(action: "restore", error: rollbackError)
            }
            connectionError = message
            return
        }

        do {
            try persistSettingsSync(nextSettings)
        } catch {
            let rollbackError = restoreRemovedAccountSecrets(
                accountEmail: account.email,
                accountPassword: previousAccountPassword,
                legacyPassword: shouldRemoveLegacyPassword ? previousLegacyPassword : nil
            )
            var message = Self.settingsMessage(action: "save", error: error)
            if let rollbackError {
                message += " " + Self.keychainMessage(action: "restore", error: rollbackError)
            }
            connectionError = message
            return
        }

        savedAccounts = nextSettings.savedAccounts

        if wasActive {
            goOfflineAfterRemovingActiveAccount()
        }
        logger.info("Saved account removed")
    }

    private func restoreRemovedAccountSecrets(
        accountEmail: String,
        accountPassword: String?,
        legacyPassword: String?
    ) -> Error? {
        do {
            if let accountPassword {
                try secrets.set(accountPassword, for: .mailAppPassword(email: accountEmail))
            }
            if let legacyPassword {
                try secrets.set(legacyPassword, for: .mailAppPassword)
            }
            return nil
        } catch {
            logger.error("Failed to roll back removed mail secret: \(error.localizedDescription)")
            return error
        }
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

    // MARK: - Verified-connection persistence

    /// Adopts verified credentials as the active account, remembers it, and
    /// persists the settings snapshot. Called from `testConnection`.
    func persistVerifiedConnection(_ credentials: MailAccountCredentials) throws {
        mailEmail = credentials.email
        mailHost = credentials.host
        mailPort = credentials.port
        mailAppPassword = credentials.appPassword
        markMailHostVerifiedForGuidance()
        // Remember this account so it can be switched back to without re-entry.
        upsertSavedAccount(email: credentials.email, host: credentials.host, port: credentials.port)

        try persistSettingsSync(buildSettings(
            mailEmail: credentials.email,
            mailHost: credentials.host,
            mailPort: credentials.port
        ))
    }

    /// Restores the connecting account's Keychain slot after a failed persist.
    func rollbackMailAppPassword(to previousAppPassword: String?, for key: SecretKey) -> Error? {
        do {
            if let previousAppPassword {
                try secrets.set(previousAppPassword, for: key)
            } else {
                try secrets.remove(key)
            }
            return nil
        } catch {
            logger.error("Failed to roll back mail app password: \(error.localizedDescription)")
            return error
        }
    }

    /// Restores UI/account state to a previous settings snapshot after a failed
    /// connect. Per-account keys are isolated, so the previously-active account's
    /// secret was never touched by the failed attempt — it is re-read honestly.
    func restoreConnectionSnapshot(settings: Settings) {
        mailEmail = settings.mailEmail
        mailHost = settings.mailHost
        mailPort = settings.mailPort
        savedAccounts = settings.savedAccounts
        mailHostExplicitlyEditedEmail = settings.mailHostGuidanceEmail
        mailHostExplicitlyEditedBeforeEmail = settings.mailHostGuidancePendingEmail
        let previousEmail = settings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousPassword = storedMailPassword(forEmail: previousEmail) ?? ""
        mailAppPassword = previousPassword
        isAccountConnected = !previousEmail.isEmpty && !previousPassword.isEmpty
        restoreMailHostGuidanceFromSettings(settings)
    }
}
