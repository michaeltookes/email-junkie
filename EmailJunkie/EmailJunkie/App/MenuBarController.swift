import AppKit
import SwiftUI

/// Manages the menu bar icon and dropdown menu.
///
/// The menu bar is the primary access point for Email Junkie. The menu is
/// rebuilt on demand (`menuNeedsUpdate`) so the status line and toggle states
/// always reflect current `AppState`.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private let appState: AppState
    private let updateManager: UpdateManager

    /// The settings window, created lazily.
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(appState: AppState, updateManager: UpdateManager) {
        self.appState = appState
        self.updateManager = updateManager
        super.init()
        setupStatusItem()
    }

    deinit {
        if let observer = settingsCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "envelope.badge",
                accessibilityDescription: "Email Junkie"
            )
            button.image?.isTemplate = true  // Adapts to light/dark menu bar.
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenuItems() {
            menu.addItem(item)
        }
    }

    private func buildMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // Header (disabled label)
        let header = NSMenuItem(title: "Email Junkie", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)

        // Status line (disabled label)
        let status = NSMenuItem(title: appState.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        items.append(status)

        items.append(.separator())

        // Settings…
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        items.append(settings)

        items.append(.separator())

        // Launch at Login toggle
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = appState.launchAtLogin ? .on : .off
        items.append(login)

        // Check for Updates
        let updateTitle = updateManager.isConfigured
            ? "Check for Updates…"
            : "Check for Updates (Unavailable)"
        let update = NSMenuItem(title: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = updateManager.canCheckForUpdates
        if let reason = updateManager.unavailableReason {
            update.toolTip = reason
        }
        items.append(update)

        items.append(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit Email Junkie", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        items.append(quit)

        return items
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        appState.setLaunchAtLogin(!appState.launchAtLogin)
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updateManager.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(appState)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Email Junkie Settings"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            window.setAccessibilityLabel("Email Junkie Settings")
            settingsWindow = window

            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if let observer = self?.settingsCloseObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self?.settingsCloseObserver = nil
                    }
                    self?.settingsWindow = nil
                }
            }
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
