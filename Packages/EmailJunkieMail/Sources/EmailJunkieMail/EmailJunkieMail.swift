import NIOCore
import NIOIMAP
import NIOSSL

/// Umbrella namespace for the Email Junkie mail layer.
///
/// This module wraps the SwiftNIO IMAP stack (`NIOIMAP` over `NIOSSL`) behind a
/// small, app-facing mail API. The imports above exist so the dependency graph
/// is exercised at build time; real functionality is added incrementally.
public enum EmailJunkieMail {
    /// Marker used by the smoke test to confirm the module links.
    public static let isLinked = true
}
