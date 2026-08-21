import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "URLCallback")

/// Routes an incoming `sentwise://` deep link to the right sign-in/provisioning
/// completion (item 59). Called from `AppDelegate.application(_:open:)`.
extension AppState {

    /// Dispatches a custom-scheme URL. Unrecognized URLs (foreign scheme, unknown
    /// host, missing parameter) are logged and ignored — never acted on.
    func handleIncomingURL(_ url: URL) {
        guard let callback = SentwiseURLCallback(url: url) else {
            logger.error("Ignoring unrecognized incoming URL")
            return
        }
        switch callback {
        case .managedOAuth(let nonce):
            Task { await handleManagedOAuthCallback(nonce: nonce) }
        case .openRouter(let code):
            Task { await handleOpenRouterCallback(code: code) }
        }
    }
}
