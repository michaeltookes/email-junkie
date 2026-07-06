import Combine
import EmailJunkieMail
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "AppState")

/// Central application state container — the single source of truth.
///
/// Views observe this object and update reactively. It holds the watch status,
/// launch-at-login preference, inbox poll interval, and the IMAP mail account
/// connection. (The parked OAuth engine remains in the codebase but is no longer
/// wired here — IMAP + app password is the primary connection path.)
@MainActor
final class AppState: ObservableObject {

    // MARK: - Watch State

    /// High-level state of the inbox watcher.
    enum WatchStatus: Equatable {
        case idle
        case watching
        case paused
    }

    /// Current watcher status. Drives the menu-bar status line.
    @Published var watchStatus: WatchStatus = .idle

    /// Number of drafts awaiting the user's approval.
    @Published var pendingDraftCount: Int = 0

    /// Whether an email account is connected.
    @Published var isAccountConnected: Bool = false

    /// Whether a connection attempt is in progress.
    @Published var isConnecting: Bool = false

    /// A user-facing message describing the last connection error, if any.
    @Published var connectionError: String?

    // MARK: - Mail Account Inputs (bound to Settings fields)

    @Published var mailEmail: String
    @Published var mailAppPassword: String
    @Published var mailHost: String
    @Published var mailPort: Int

    // MARK: - Recent Messages (preview)

    /// The most recently fetched messages (envelope-level), newest first.
    @Published var recentMessages: [MailMessage] = []

    /// Whether a fetch is in progress.
    @Published var isFetching: Bool = false

    /// A user-facing message describing the last fetch error, if any.
    @Published var fetchError: String?

    /// The readable body of the message the user opened, if any.
    @Published var openedBody: MailBodyPreview?

    /// Whether a body fetch is in progress.
    @Published var isFetchingBody: Bool = false

    /// A user-facing message describing the last body-fetch error, if any.
    @Published var bodyError: String?

    // MARK: - Preferences

    /// Whether the app launches at login (mirrors `SMAppService` state).
    @Published private(set) var launchAtLogin: Bool

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    @Published var pollIntervalSeconds: Int

    // MARK: - Private

    private let persistence: PersistenceProvider
    private let secrets: SecretStore
    private let mailProvider: MailProvider
    private let settingsDebouncer = Debouncer(delay: 0.5)
    private var cancellables = Set<AnyCancellable>()
    private var previewGeneration = 0
    private var bodyPreviewGeneration = 0
    private static let legacyOAuthKeys: [SecretKey] = [
        .gmailToken,
        .googleClientID,
        .googleClientSecret
    ]

    // MARK: - Computed

    /// Human-readable status for the menu bar.
    var statusText: String {
        guard isAccountConnected else { return "No account connected" }
        switch watchStatus {
        case .idle:
            return "Idle"
        case .watching:
            return pendingDraftCount > 0
                ? "\(pendingDraftCount) draft\(pendingDraftCount == 1 ? "" : "s") pending"
                : "Watching inbox"
        case .paused:
            return "Paused"
        }
    }

    // MARK: - Initialization

    init(
        persistence: PersistenceProvider = PersistenceService.shared,
        secrets: SecretStore = KeychainStore.shared,
        mailProvider: MailProvider = IMAPMailProvider()
    ) {
        self.persistence = persistence
        self.secrets = secrets
        self.mailProvider = mailProvider

        let settings = persistence.loadSettings()
        self.pollIntervalSeconds = settings.pollIntervalSeconds
        self.mailEmail = settings.mailEmail
        self.mailHost = settings.mailHost
        self.mailPort = settings.mailPort
        self.mailAppPassword = ((try? secrets.value(for: .mailAppPassword)) ?? nil) ?? ""
        self.launchAtLogin = LoginItemManager.shared.isEnabled

        cleanupLegacyOAuthCredentials()
        self.isAccountConnected = !settings.mailEmail.isEmpty && secrets.hasValue(for: .mailAppPassword)

        setupAutoSave()
    }

    // MARK: - Mail Account

    /// Builds credentials from the current inputs.
    private var mailCredentials: MailAccountCredentials {
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

        let credentials = mailCredentials
        guard credentials.isComplete else {
            connectionError = "Enter your email address and app password first."
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            try await mailProvider.verifyConnection(credentials)
        } catch {
            connectionError = Self.message(for: error)
            return
        }

        let previousSettings = persistence.loadSettings()
        let previousAppPassword: String?
        do {
            previousAppPassword = try secrets.value(for: .mailAppPassword)
        } catch {
            connectionError = Self.keychainMessage(action: "read", error: error)
            return
        }

        do {
            try secrets.set(credentials.appPassword, for: .mailAppPassword)
        } catch {
            connectionError = Self.keychainMessage(action: "save", error: error)
            return
        }

        do {
            try persistVerifiedConnection(credentials)
        } catch {
            let rollbackError = rollbackMailAppPassword(to: previousAppPassword)
            restoreConnectionSnapshot(settings: previousSettings, appPassword: previousAppPassword)
            var message = Self.settingsMessage(action: "save", error: error)
            if let rollbackError {
                message += " " + Self.keychainMessage(action: "restore", error: rollbackError)
            }
            connectionError = message
            return
        }
        isAccountConnected = true
        resetRecentMessagePreviewForAccountChange()
        logger.info("Mailbox connected")
    }

    /// Disconnects the mailbox by clearing the stored app password.
    func disconnectMail() {
        connectionError = nil
        do {
            try removeLegacyOAuthCredentialsIfPresent()
        } catch {
            connectionError = Self.legacyOAuthCleanupMessage(error: error)
            return
        }

        do {
            try secrets.remove(.mailAppPassword)
        } catch {
            connectionError = Self.keychainMessage(action: "remove", error: error)
            return
        }
        mailAppPassword = ""
        isAccountConnected = false
        resetRecentMessagePreviewForAccountChange()
        logger.info("Mailbox disconnected")
    }

    /// Fetches recent messages from a mailbox for a quick preview.
    func previewRecentMessages(mailbox: Mailbox = .inbox, limit: Int = 10) async {
        let requestGeneration = nextPreviewGeneration()
        clearRecentMessagePreview()
        isFetching = false

        let credentials = mailCredentials
        guard credentials.isComplete else {
            fetchError = "Connect an account first."
            return
        }

        isFetching = true
        defer {
            if previewGeneration == requestGeneration {
                isFetching = false
            }
        }

        do {
            let messages = try await mailProvider.fetchRecentMessages(
                credentials,
                mailbox: mailbox,
                limit: limit
            )
            guard isCurrentPreviewRequest(requestGeneration, credentials: credentials) else { return }
            recentMessages = messages
        } catch {
            guard isCurrentPreviewRequest(requestGeneration, credentials: credentials) else { return }
            recentMessages = []
            fetchError = Self.message(for: error)
        }
    }

    /// Fetches and reduces a single message's body to readable text for preview.
    func previewBody(for message: MailMessage, mailbox: Mailbox = .inbox) async {
        let requestGeneration = nextBodyPreviewGeneration()
        bodyError = nil
        openedBody = nil
        isFetchingBody = false

        let credentials = mailCredentials
        guard credentials.isComplete else {
            bodyError = "Connect an account first."
            return
        }

        isFetchingBody = true
        defer {
            if bodyPreviewGeneration == requestGeneration {
                isFetchingBody = false
            }
        }

        do {
            let raw = try await mailProvider.fetchBodyText(
                credentials,
                mailbox: mailbox,
                uid: message.id
            )
            guard isCurrentBodyPreviewRequest(requestGeneration, credentials: credentials) else { return }
            openedBody = MailBodyPreview(
                id: message.id,
                subject: message.subject,
                text: MailBodyText.plainText(from: raw)
            )
        } catch {
            guard isCurrentBodyPreviewRequest(requestGeneration, credentials: credentials) else { return }
            bodyError = Self.message(for: error)
        }
    }

    private func nextPreviewGeneration() -> Int {
        previewGeneration += 1
        return previewGeneration
    }

    private func nextBodyPreviewGeneration() -> Int {
        bodyPreviewGeneration += 1
        return bodyPreviewGeneration
    }

    private func resetRecentMessagePreviewForAccountChange() {
        _ = nextPreviewGeneration()
        _ = nextBodyPreviewGeneration()
        clearRecentMessagePreview()
        isFetching = false
        isFetchingBody = false
    }

    private func clearRecentMessagePreview() {
        recentMessages = []
        fetchError = nil
        openedBody = nil
        bodyError = nil
    }

    private func isCurrentPreviewRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials
    ) -> Bool {
        previewGeneration == requestGeneration && mailCredentials == credentials
    }

    private func isCurrentBodyPreviewRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials
    ) -> Bool {
        bodyPreviewGeneration == requestGeneration && mailCredentials == credentials
    }

    /// Maps an error to a concise, user-facing message.
    private static func message(for error: Error) -> String {
        switch error {
        case MailError.incompleteCredentials:
            return "Enter your email address and app password first."
        case MailError.authenticationFailed(let detail):
            return "Sign-in failed — check your email and app password. (\(detail))"
        case MailError.connectionFailed(let detail):
            return "Couldn't reach the mail server. (\(detail))"
        case MailError.commandFailed(let detail):
            return "The mail server rejected a request. (\(detail))"
        case KeychainError.unexpectedStatus(let status):
            return "Keychain returned status \(status)."
        case KeychainError.dataEncodingFailed:
            return "Keychain could not encode the app password."
        default:
            return error.localizedDescription
        }
    }

    private static func keychainMessage(action: String, error: Error) -> String {
        "Couldn't \(action) the app password in Keychain. \(message(for: error))"
    }

    private static func legacyOAuthCleanupMessage(error: Error) -> String {
        "Couldn't remove the legacy Gmail OAuth credentials from Keychain. \(message(for: error))"
    }

    private static func settingsMessage(action: String, error: Error) -> String {
        "Couldn't \(action) mailbox settings. \(message(for: error))"
    }

    private func cleanupLegacyOAuthCredentials() {
        do {
            try removeLegacyOAuthCredentialsIfPresent()
        } catch {
            connectionError = Self.legacyOAuthCleanupMessage(error: error)
        }
    }

    private func removeLegacyOAuthCredentialsIfPresent() throws {
        var removedAnyCredential = false
        for key in Self.legacyOAuthKeys where try secrets.value(for: key) != nil {
            try secrets.remove(key)
            removedAnyCredential = true
        }

        if removedAnyCredential {
            logger.info("Legacy Gmail OAuth credentials removed")
        }
    }

    /// Persists settings automatically when a tracked preference changes.
    private func setupAutoSave() {
        $pollIntervalSeconds
            .dropFirst()
            .sink { [weak self] _ in self?.saveSettings() }
            .store(in: &cancellables)
    }

    // MARK: - Launch at Login

    /// Updates the launch-at-login preference via `SMAppService`.
    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItemManager.shared.setEnabled(enabled)
        // Re-read the authoritative status so the UI reflects reality even if
        // the system rejected the change.
        launchAtLogin = LoginItemManager.shared.isEnabled
    }

    // MARK: - Persistence

    private func persistVerifiedConnection(_ credentials: MailAccountCredentials) throws {
        mailEmail = credentials.email
        mailHost = credentials.host
        mailPort = credentials.port
        mailAppPassword = credentials.appPassword

        settingsDebouncer.cancel()
        try persistence.saveSettingsSync(buildSettings(
            mailEmail: credentials.email,
            mailHost: credentials.host,
            mailPort: credentials.port
        ))
    }

    private func rollbackMailAppPassword(to previousAppPassword: String?) -> Error? {
        do {
            if let previousAppPassword {
                try secrets.set(previousAppPassword, for: .mailAppPassword)
            } else {
                try secrets.remove(.mailAppPassword)
            }
            return nil
        } catch {
            logger.error("Failed to roll back mail app password: \(error.localizedDescription)")
            return error
        }
    }

    private func restoreConnectionSnapshot(settings: Settings, appPassword: String?) {
        mailEmail = settings.mailEmail
        mailHost = settings.mailHost
        mailPort = settings.mailPort
        mailAppPassword = appPassword ?? ""
        isAccountConnected = !settings.mailEmail.isEmpty && !(appPassword ?? "").isEmpty
    }

    private func buildSettings(
        mailEmail: String? = nil,
        mailHost: String? = nil,
        mailPort: Int? = nil
    ) -> Settings {
        Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: pollIntervalSeconds,
            mailEmail: (mailEmail ?? self.mailEmail).trimmingCharacters(in: .whitespacesAndNewlines),
            mailHost: (mailHost ?? self.mailHost).trimmingCharacters(in: .whitespacesAndNewlines),
            mailPort: mailPort ?? self.mailPort
        )
    }

    /// Saves settings to disk (debounced).
    func saveSettings() {
        let settings = buildSettings()
        settingsDebouncer.debounce { [weak self] in
            self?.persistence.saveSettings(settings)
        }
    }

    /// Saves settings immediately (used on app termination).
    func saveSettingsSync() {
        let settings = buildSettings()
        settingsDebouncer.cancel()
        do {
            try persistence.saveSettingsSync(settings)
        } catch {
            connectionError = Self.settingsMessage(action: "save", error: error)
            logger.error("Failed to save settings synchronously: \(error.localizedDescription)")
        }
    }
}

/// A fetched, readable message body shown in the preview sheet.
struct MailBodyPreview: Identifiable, Equatable {
    /// The source message's IMAP UID.
    let id: UInt32
    let subject: String
    let text: String
}
