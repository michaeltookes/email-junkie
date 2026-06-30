import SwiftUI

/// Main entry point for Email Junkie.
///
/// This is a menu bar application (`LSUIElement = YES`) that watches the user's
/// inbox, drafts replies in their voice, and surfaces them for approval.
/// All UI is driven from the `AppDelegate`; the empty `WindowGroup` here exists
/// only because SwiftUI requires at least one scene.
@main
struct EmailJunkieApp: App {
    /// Handles `NSApplication` lifecycle and menu-bar setup.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar apps don't need a visible main window.
        // We use a zero-size WindowGroup that is never shown.
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
        }
        .windowResizability(.contentSize)
    }
}
