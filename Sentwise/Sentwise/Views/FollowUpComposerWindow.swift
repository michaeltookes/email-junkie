import AppKit
import SwiftUI

/// Owns the follow-up composer window (item 51), created lazily and torn down on
/// close. Kept out of `MenuBarController` so that controller stays within length
/// limits; the controller holds one instance and calls `present(appState:)`.
@MainActor
final class FollowUpComposerWindow {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func present(appState: AppState) {
        if window == nil {
            let view = FollowUpComposerView()
                .environmentObject(appState)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "New Follow-up"
            win.contentView = NSHostingView(rootView: view)
            win.center()
            win.isReleasedWhenClosed = false
            win.setAccessibilityLabel("New Follow-up")
            window = win

            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.teardown() }
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func teardown() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        window = nil
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}
