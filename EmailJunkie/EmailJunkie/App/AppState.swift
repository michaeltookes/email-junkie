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

    /// Whether an email account is connected. False until Gmail OAuth lands.
    @Published var isAccountConnected: Bool = false

    // MARK: - Preferences

    /// Whether the app launches at login (mirrors `SMAppService` state).
    @Published private(set) var launchAtLogin: Bool

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    @Published var pollIntervalSeconds: Int

    // MARK: - Private

    private let persistence: PersistenceProvider
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

    init(persistence: PersistenceProvider = PersistenceService.shared) {
        self.persistence = persistence

        let settings = persistence.loadSettings()
        self.pollIntervalSeconds = settings.pollIntervalSeconds
        self.launchAtLogin = LoginItemManager.shared.isEnabled

        setupAutoSave()
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
