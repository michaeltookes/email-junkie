import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "Connection")

/// Mail-account connect/disconnect on `AppState`. Split out of `AppState` so that
/// file stays within length limits; the verify → persist → adopt flow and its
/// rollback are unchanged.
extension AppState {

    /// Builds credentials from the current inputs.
    var mailCredentials: MailAccountCredentials {
        MailAccountCredentials(
            email: mailEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            appPassword: mailAppPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            host: mailHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: mailPort
        )
    }

    /// Tests the mailbox connection and, on success, saves the credentials.
    func testConnection() async {
        connectionError = nil
        commitMailEmailEditFromUser()

        await testConnection(with: mailCredentials)
    }

    /// Tests the mailbox connection from an explicit credential snapshot and, on
    /// success, adopts it as the active account.
    func testConnection(with credentials: MailAccountCredentials) async {
        connectionError = nil
        let credentials = MailAccountCredentials(
            email: credentials.email.trimmingCharacters(in: .whitespacesAndNewlines),
            appPassword: credentials.appPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            host: credentials.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: credentials.port
        )
        guard credentials.isComplete else {
            connectionError = "Enter your email address and app password first."
            return
        }

        isConnecting = true
        defer { isConnecting = false }
        let wasWatching = watchStatus == .watching

        do {
            try await mailProvider.verifyConnection(credentials)
        } catch {
            connectionError = Self.message(for: error)
            return
        }

        let previousSettings = persistence.loadSettings()
        let accountChanged = !isAccountConnected
            || previousSettings.mailEmail.caseInsensitiveCompare(credentials.email) != .orderedSame
        // Per-account key (item 48): writing a second account never overwrites the
        // first account's secret, so switching back to it later needs no re-entry.
        let accountKey = SecretKey.mailAppPassword(email: credentials.email)
        let previousAppPassword: String?
        do {
            previousAppPassword = try secrets.value(for: accountKey)
        } catch {
            connectionError = Self.keychainMessage(action: "read", error: error)
            return
        }

        do {
            try secrets.set(credentials.appPassword, for: accountKey)
        } catch {
            connectionError = Self.keychainMessage(action: "save", error: error)
            return
        }

        do {
            try persistVerifiedConnection(credentials)
        } catch {
            let rollbackError = rollbackMailAppPassword(to: previousAppPassword, for: accountKey)
            restoreConnectionSnapshot(settings: previousSettings)
            var message = Self.settingsMessage(action: "save", error: error)
            if let rollbackError {
                message += " " + Self.keychainMessage(action: "restore", error: rollbackError)
            }
            connectionError = message
            return
        }
        isAccountConnected = true
        if accountChanged {
            // A different account invalidates any in-flight auto-send countdowns
            // (item 23) and offline-queued dispatches (item 27); neither must fire
            // against the newly connected account.
            cancelAllSendCountdowns()
            clearAllOfflineQueueEntries()
            if wasWatching {
                stopWatching()
                startWatchingIfReady()
            }
        }
        resetMessagePreviewForAccountChange(clearSkippedMessages: accountChanged)
        logger.info("Mailbox connected")
    }

    /// Disconnects the mailbox by clearing the stored app password.
    func disconnectMail() {
        connectionError = nil
        guard !isConnecting else {
            logger.info("Disconnect skipped while a connection test is running")
            return
        }
        do {
            try removeLegacyOAuthCredentialsIfPresent()
        } catch {
            connectionError = Self.legacyOAuthCleanupMessage(error: error)
            return
        }

        guard removeActiveMailPasswordForDisconnect() else { return }
        mailAppPassword = ""
        markMailHostVerifiedForGuidance()
        isAccountConnected = false
        cancelAllSendCountdowns()
        clearAllOfflineQueueEntries()
        stopWatching()
        resetMessagePreviewForAccountChange()
        logger.info("Mailbox disconnected")
    }
}
