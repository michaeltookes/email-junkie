import Foundation
import Network

/// An injectable seam over reachability so the app can pause work while offline
/// and resume on reconnect (item 27), and tests can drive offline→online
/// transitions deterministically without touching real network state.
@MainActor
protocol NetworkReachabilityMonitoring: AnyObject {
    /// Whether the network currently appears usable.
    var isOnline: Bool { get }
    /// Whether the monitor has delivered at least one concrete path value.
    var hasCurrentPath: Bool { get }
    /// Invoked on the main actor whenever reachability changes. Set by `AppState`.
    var onChange: ((Bool) -> Void)? { get set }
    /// Begins monitoring. Idempotent.
    func start()
    /// Stops monitoring.
    func stop()
}

/// The production reachability monitor, backed by `NWPathMonitor`. Path updates
/// arrive on a background queue and are hopped to the main actor before touching
/// `isOnline` or notifying `AppState`.
@MainActor
final class NetworkReachabilityMonitor: NetworkReachabilityMonitoring {

    private(set) var isOnline: Bool = true
    private(set) var hasCurrentPath = false
    var onChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.tookes.EmailJunkie.reachability")
    private var isStarted = false

    /// Nonisolated so it can serve as a default argument for `AppState.init`
    /// (which evaluates default args outside the main actor). No stored property
    /// requires main-actor setup — they all use nonisolated default initializers.
    nonisolated init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.apply(online: online)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.cancel()
    }

    private func apply(online: Bool) {
        let isInitialPath = !hasCurrentPath
        hasCurrentPath = true
        guard isInitialPath || online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
