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

        appState = AppState()
        updateManager = UpdateManager()
        menuBarController = MenuBarController(appState: appState, updateManager: updateManager)
        updateManager.startUpdater()

        logger.info("Email Junkie launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending settings to disk before quitting.
        appState.saveSettingsSync()
        logger.info("Email Junkie terminating")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
