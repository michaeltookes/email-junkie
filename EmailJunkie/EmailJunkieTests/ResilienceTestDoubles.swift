import Foundation
@testable import EmailJunkie

/// A reachability monitor whose online/offline state tests drive directly, so
/// offline→online transitions are deterministic and never touch real networking.
@MainActor
final class FakeReachabilityMonitor: NetworkReachabilityMonitoring {
    private(set) var isOnline: Bool
    private(set) var hasCurrentPath: Bool
    var onChange: ((Bool) -> Void)?
    private(set) var didStart = false
    var isStarted: Bool { didStart }

    init(isOnline: Bool = true, hasCurrentPath: Bool = true) {
        self.isOnline = isOnline
        self.hasCurrentPath = hasCurrentPath
    }

    func start() { didStart = true }
    func stop() { didStart = false }

    /// Flips reachability and notifies the observer, mirroring the production
    /// monitor's change-or-initial-path semantics.
    func setOnline(_ online: Bool) {
        let isInitialPath = !hasCurrentPath
        hasCurrentPath = true
        guard isInitialPath || online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}

extension RetryRunner {
    /// A runner that retries under the default attempt budget but never actually
    /// sleeps, with deterministic (midpoint) jitter — so retry behavior is
    /// exercised in tests without real backoff waits.
    static var immediate: RetryRunner {
        RetryRunner(sleep: { _ in }, randomUnitInterval: { 0.5 })
    }
}
