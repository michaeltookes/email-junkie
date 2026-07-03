import AppKit
import Combine
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "AppState")

/// Central application state container — the single source of truth.
///
/// Views observe this object and update reactively. For now it holds the
/// watch status, the launch-at-login preference, and the inbox poll interval.
/// The email/voice/draft machinery is layered on in later milestones.
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

    /// Whether a Gmail connection attempt is in progress.
    @Published var isConnecting: Bool = false

    /// A user-facing message describing the last connection error, if any.
    @Published var connectionError: String?

    /// The BYO Google OAuth client ID, bound to the Settings field.
    @Published var clientIDInput: String = ""

    /// The BYO Google OAuth client secret, bound to the Settings field.
    @Published var clientSecretInput: String = ""

    // MARK: - Preferences

    /// Whether the app launches at login (mirrors `SMAppService` state).
    @Published private(set) var launchAtLogin: Bool

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    @Published var pollIntervalSeconds: Int

    // MARK: - Private

    private let persistence: PersistenceProvider
    private let gmailStore: GmailAuthStore
    private let gmailAuth: GmailAuthCoordinator
    private let settingsDebouncer = Debouncer(delay: 0.5)
    private var cancellables = Set<AnyCancellable>()

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
        gmailStore: GmailAuthStore = GmailAuthStore(),
        gmailAuth: GmailAuthCoordinator? = nil
    ) {
        self.persistence = persistence
        self.gmailStore = gmailStore
        self.gmailAuth = gmailAuth ?? GmailAuthCoordinator(
            store: gmailStore,
            tokenService: OAuthTokenService(transport: URLSessionTransport()),
            makeListener: { LoopbackRedirectListener() },
            browser: NSWorkspaceBrowserOpener()
        )

        let settings = persistence.loadSettings()
        self.pollIntervalSeconds = settings.pollIntervalSeconds
        self.launchAtLogin = LoginItemManager.shared.isEnabled

        self.isAccountConnected = gmailStore.isConnected
        if let credentials = try? gmailStore.loadCredentials() {
            self.clientIDInput = credentials.clientID
            self.clientSecretInput = credentials.clientSecret
        }

        setupAutoSave()
    }

    // MARK: - Gmail Account

    /// Saves the entered BYO OAuth client credentials to the Keychain.
    func saveGmailCredentials() throws {
        let credentials = GmailCredentials(
            clientID: clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try gmailStore.saveCredentials(credentials)
    }

    /// Runs the Gmail connect flow, updating connection state and any error.
    func connectGmail() async {
        connectionError = nil

        let clientID = clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            connectionError = "Enter your Google OAuth client ID and secret first."
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            try saveGmailCredentials()
            _ = try await gmailAuth.connect()
            isAccountConnected = true
        } catch {
            connectionError = Self.message(for: error)
        }
    }

    /// Disconnects the Gmail account (clears the token, keeps credentials).
    func disconnectGmail() {
        connectionError = nil
        do {
            try gmailAuth.disconnect()
            isAccountConnected = false
        } catch {
            connectionError = Self.message(for: error)
        }
    }

    /// Maps an error to a concise, user-facing message.
    private static func message(for error: Error) -> String {
        switch error {
        case GmailAuthError.missingCredentials:
            return "Enter your Google OAuth client ID and secret first."
        case OAuthError.stateMismatch:
            return "Security check failed. Please try connecting again."
        case OAuthError.authorizationDenied:
            return "Access was declined in the browser."
        case OAuthError.redirectTimedOut:
            return "Connection timed out. Please try again."
        case OAuthError.missingRequiredScopes:
            return "Grant all requested Gmail permissions, then try connecting again."
        case let OAuthError.server(code, description):
            return description ?? "Google returned an error (\(code))."
        default:
            return error.localizedDescription
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

    private func buildSettings() -> Settings {
        Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: pollIntervalSeconds
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
        persistence.saveSettingsSync(settings)
    }
}
