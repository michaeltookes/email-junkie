import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "AppDelegate")

/// Manages the application lifecycle and coordinates the top-level components.
///
/// Responsibilities:
/// - Hide the Dock icon (menu-bar-only app)
/// - Initialize the central `AppState`
/// - Set up the menu bar controller
/// - Start the (currently no-op) update manager
/// - Persist settings on termination
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    /// Central state container for the application.
    private var appState: AppState!

    /// Manages the menu bar icon and dropdown menu.
    private var menuBarController: MenuBarController!

    /// Manages application updates (Sparkle is wired in at the distribution milestone).
    private var updateManager: UpdateManager!

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon. LSUIElement handles this too,
        // but we set it explicitly to be safe.
        NSApp.setActivationPolicy(.accessory)

        appState = AppState(notifier: UserNotificationService())
        updateManager = UpdateManager()
        menuBarController = MenuBarController(appState: appState, updateManager: updateManager)
        updateManager.startUpdater()

        // Ask for notification permission so ready drafts can surface natively.
        appState.notifier.requestAuthorization()

        // Begin watching reachability so work pauses offline and resumes on
        // reconnect (item 27).
        appState.startReachabilityMonitoring()

        // First-run onboarding: show the setup assistant until it's completed
        // once. An already-configured install is reconciled to "complete" so
        // existing users are never sent back through the flow.
        if appState.reconcileOnboardingState() {
            appState.openOnboardingHandler?()
        } else {
            // Auto-resume watching if an account + LLM are already connected.
            appState.startWatchingIfReady()
        }

        // Resume watching the transcript folder if it was left enabled (item 51).
        appState.startTranscriptFolderWatchingIfEnabled()

        logger.info("Email Junkie launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending edits/settings to disk before quitting.
        appState.flushPendingDraftBodyEdits()
        // Outstanding auto-send countdowns (item 23) must not fire during teardown;
        // their drafts remain pending in the persisted queue.
        appState.cancelAllSendCountdowns()
        appState.stopReachabilityMonitoring()
        appState.stopTranscriptFolderWatching()
        appState.saveSettingsSync()
        logger.info("Email Junkie terminating")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
