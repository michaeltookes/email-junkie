import SwiftUI

/// Main entry point for Email Junkie.
///
/// This is a menu bar application (`LSUIElement = YES`) that watches the user's
/// inbox, drafts replies in their voice, and surfaces them for approval.
/// All UI is driven from the `AppDelegate`; the empty `Settings` scene exists
/// only because SwiftUI requires at least one scene and it does not open a
/// default window at launch.
@main
struct EmailJunkieApp: App {
    /// Handles `NSApplication` lifecycle and menu-bar setup.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        SwiftUI.Settings {
            EmptyView()
        }
    }
}
