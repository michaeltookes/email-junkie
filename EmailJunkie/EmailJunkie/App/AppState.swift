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

    // MARK: - AI Provider (bound to Settings fields)

    /// The selected LLM provider.
    @Published var llmProviderKind: LLMProviderKind
    /// The chosen model id (empty = provider default).
    @Published var llmModel: String
    /// The API key input (persisted to Keychain on a successful test).
    @Published var llmAPIKey: String
    /// Whether an LLM provider is connected (a verified key is stored).
    @Published var isLLMConnected: Bool = false
    /// Whether an LLM connection test is in progress.
    @Published var isTestingLLM: Bool = false
    /// A user-facing message describing the last LLM error, if any.
    @Published var llmError: String?

    /// The resolved model id that last passed a connection test.
    var verifiedLLMModel: String

    // MARK: - Voice Profile

    /// The learned voice profile, or `nil` if none has been learned yet.
    @Published var voiceProfile: VoiceProfile?
    /// Whether voice learning is in progress.
    @Published var isLearningVoice: Bool = false
    /// A short progress message shown while learning.
    @Published var voiceProgress: String?
    /// A user-facing message describing the last voice-learning error, if any.
    @Published var voiceError: String?

    // MARK: - Draft (preview)

    /// The most recently generated reply draft, if any.
    @Published var generatedDraft: Draft?
    /// Whether a draft is being generated.
    @Published var isGeneratingDraft: Bool = false
    /// A user-facing message describing the last draft error, if any.
    @Published var draftError: String?
    /// Whether the current draft is being saved to the Drafts mailbox.
    @Published var isSavingDraft: Bool = false
    /// A confirmation message shown after a successful save, if any.
    @Published var draftSavedMessage: String?
    /// Whether the current draft is being sent over SMTP.
    @Published var isSendingDraft: Bool = false
    /// A confirmation message shown after a successful send, if any.
    @Published var draftSentMessage: String?

    // MARK: - Preferences

    /// Whether the app launches at login (mirrors `SMAppService` state).
    @Published private(set) var launchAtLogin: Bool

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    @Published var pollIntervalSeconds: Int

    /// What approving a draft does: save a Gmail draft or send immediately.
    @Published var sendBehavior: SendBehavior

    // MARK: - Inbox Watcher

    /// Drafts the watcher has produced and enqueued, awaiting approval (item 8).
    @Published var pendingDrafts: [Draft] = []

    /// A user-facing message describing the last inbox-poll error, if any.
    @Published var watchError: String?

    /// Messages the watcher has already handled, so none is drafted twice.
    var processedMessages: ProcessedMessages

    /// Reentrancy guard so overlapping polls can't double-process the inbox.
    var isPollingInbox = false

    /// The scheduling half of the watcher; the poll policy is `pollInboxOnce`.
    private(set) var inboxWatcher: InboxWatcher!

    /// How many recent inbox messages each poll inspects.
    let watchFetchLimit = 20

    // MARK: - Private

    /// Internal (not private) so the `AppState+Voice` extension can reach it.
    let persistence: PersistenceProvider
    /// Internal (not private) so the `AppState+LLM`/`+Voice` extensions can reach it.
    let secrets: SecretStore
    /// Internal (not private) so the `AppState+Voice` extension can reach it.
    let mailProvider: MailProvider
    let llm: LLMProviding
    private let settingsDebouncer = Debouncer(delay: 0.5)
    private var cancellables = Set<AnyCancellable>()
    var previewGeneration = 0
    var bodyPreviewGeneration = 0
    var draftGeneration = 0

    // MARK: - Initialization

    init(
        persistence: PersistenceProvider = PersistenceService.shared,
        secrets: SecretStore = KeychainStore.shared,
        mailProvider: MailProvider = IMAPMailProvider(),
        llm: LLMProviding = LLMService()
    ) {
        self.persistence = persistence
        self.secrets = secrets
        self.mailProvider = mailProvider
        self.llm = llm

        let settings = persistence.loadSettings()
        self.pollIntervalSeconds = settings.pollIntervalSeconds
        self.sendBehavior = SendBehavior(rawValue: settings.sendBehavior) ?? .default
        self.processedMessages = persistence.loadProcessedMessages()
        self.mailEmail = settings.mailEmail
        self.mailHost = settings.mailHost
        self.mailPort = settings.mailPort
        self.mailAppPassword = ((try? secrets.value(for: .mailAppPassword)) ?? nil) ?? ""
        self.launchAtLogin = LoginItemManager.shared.isEnabled

        let provider = LLMProviderKind(rawValue: settings.llmProvider) ?? .anthropic
        self.llmProviderKind = provider
        self.llmModel = settings.llmModel
        self.verifiedLLMModel = settings.llmVerifiedModel
        self.llmAPIKey = ((try? secrets.value(for: provider.apiKeySecret)) ?? nil) ?? ""

        self.voiceProfile = persistence.loadVoiceProfile()

        cleanupLegacyOAuthCredentials()
        self.isAccountConnected = !settings.mailEmail.isEmpty && secrets.hasValue(for: .mailAppPassword)
        refreshLLMConnectionStatus()

        setupAutoSave()

        self.inboxWatcher = InboxWatcher(
            interval: { [weak self] in TimeInterval(self?.pollIntervalSeconds ?? 300) },
            onTick: { [weak self] in await self?.pollInboxOnce() }
        )
    }

    // MARK: - Mail Account

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
        resetMessagePreviewForAccountChange()
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
        stopWatching()
        resetMessagePreviewForAccountChange()
        logger.info("Mailbox disconnected")
    }

    /// Persists settings automatically when a tracked preference changes.
    private func setupAutoSave() {
        $pollIntervalSeconds
            .dropFirst()
            .sink { [weak self] _ in
                self?.saveSettings()
                self?.inboxWatcher.reschedule()
            }
            .store(in: &cancellables)

        $sendBehavior
            .dropFirst()
            .sink { [weak self] _ in self?.saveSettings() }
            .store(in: &cancellables)

        $llmModel
            .dropFirst()
            .sink { [weak self] model in
                self?.resetDraftPreviewForLLMChange()
                self?.refreshLLMConnectionStatus(llmModel: model)
                self?.saveSettings(llmModel: model)
            }
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
        mailPort: Int? = nil,
        llmModelOverride: String? = nil
    ) -> Settings {
        Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: pollIntervalSeconds,
            mailEmail: (mailEmail ?? self.mailEmail).trimmingCharacters(in: .whitespacesAndNewlines),
            mailHost: (mailHost ?? self.mailHost).trimmingCharacters(in: .whitespacesAndNewlines),
            mailPort: mailPort ?? self.mailPort,
            llmProvider: llmProviderKind.rawValue,
            llmModel: (llmModelOverride ?? self.llmModel).trimmingCharacters(in: .whitespacesAndNewlines),
            llmVerifiedModel: verifiedLLMModel,
            sendBehavior: sendBehavior.rawValue
        )
    }

    /// Saves settings to disk (debounced).
    func saveSettings(llmModel: String? = nil) {
        let settings = buildSettings(llmModelOverride: llmModel)
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
