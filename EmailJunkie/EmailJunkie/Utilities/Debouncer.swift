import Foundation

/// Coalesces rapid calls into a single deferred action.
///
/// Used to debounce settings saves so a burst of changes results in one write.
final class Debouncer {

    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    /// Schedules `action`, cancelling any previously scheduled one.
    func debounce(_ action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancels any pending action.
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
