import AppKit
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "Updates")

/// Manages application updates.
///
/// This is a deliberate no-op stub. The real Sparkle integration is added at
/// the distribution milestone (signed DMG + appcast + auto-update). The API
/// surface here mirrors what the Sparkle-backed version will expose, so the
/// swap is drop-in and `MenuBarController` needs no changes.
@MainActor
final class UpdateManager {

    /// Whether updates are configured (appcast + signing key present).
    private(set) var isConfigured: Bool = false

    /// Why update checks are unavailable (shown as a menu tooltip).
    private(set) var unavailableReason: String? = "Auto-update is added at the distribution milestone."

    /// Whether the updater can currently check for updates.
    var canCheckForUpdates: Bool { isConfigured }

    /// Starts the updater. Call after launch completes.
    func startUpdater() {
        logger.info("Updates disabled (Sparkle not yet integrated)")
    }

    /// Manually checks for updates (user-initiated).
    func checkForUpdates() {
        logger.info("Update check requested, but the updater is unavailable")
    }
}
