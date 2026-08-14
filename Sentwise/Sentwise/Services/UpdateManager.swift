import AppKit
import os
import Sparkle

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "Updates")

/// Manages application updates via Sparkle.
///
/// Menu-bar apps must never surprise the user with UI, so the updater is
/// configured for a quiet check on launch (`SUEnableAutomaticChecks` in
/// Info.plist) plus the explicit "Check for Updates…" menu item, which is the
/// only path that shows Sparkle's update window.
///
/// The API surface (`isConfigured`, `canCheckForUpdates`, `unavailableReason`,
/// `startUpdater()`, `checkForUpdates()`) is unchanged from the earlier no-op
/// stub, so `MenuBarController` needs no changes.
///
/// - Note: The updater verifies downloads against the `SUPublicEDKey` in
///   Info.plist. Until a real EdDSA keypair is generated at release time (see
///   `docs/releasing.md`) that key is a placeholder, so updates will simply
///   fail signature verification rather than install — the app still launches
///   and runs normally.
@MainActor
final class UpdateManager {

    /// The standard Sparkle controller. Created with `startingUpdater: false`
    /// so we can start it explicitly (and catch a start failure gracefully)
    /// rather than letting Sparkle pop a modal alert at launch.
    private let updaterController: SPUStandardUpdaterController

    /// Whether the updater started successfully (feed + key wired).
    private(set) var isConfigured: Bool = false

    /// Why update checks are unavailable (shown as a menu tooltip). `nil` once
    /// the updater is running.
    private(set) var unavailableReason: String? =
        "Auto-update starts once the app finishes launching."

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether the updater can currently check for updates. Sparkle exposes this
    /// as a KVO property that is briefly false while a check is in flight; the
    /// menu is rebuilt on demand so it always reflects the live value.
    var canCheckForUpdates: Bool {
        isConfigured && updaterController.updater.canCheckForUpdates
    }

    /// Starts the updater. Call after launch completes. A start failure (e.g. a
    /// malformed feed URL or public key) leaves the app fully usable with
    /// updates disabled instead of interrupting the user.
    func startUpdater() {
        do {
            try updaterController.updater.start()
            isConfigured = true
            unavailableReason = nil
            logger.info("Sparkle updater started")
        } catch {
            isConfigured = false
            unavailableReason =
                "Auto-update is unavailable until a signed release with a valid update key ships."
            logger.error("Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }

    /// Manually checks for updates (user-initiated). Shows Sparkle's update UI.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
