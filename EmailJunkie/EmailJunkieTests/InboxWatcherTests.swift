import XCTest
@testable import EmailJunkie

@MainActor
final class InboxWatcherTests: XCTestCase {

    func testRestartQueuesImmediateTickAfterInFlightTickCompletes() async {
        let firstTickStarted = expectation(description: "first tick started")
        let secondTickStarted = expectation(description: "second tick started")
        var tickCount = 0
        var firstTickContinuation: CheckedContinuation<Void, Never>?

        let watcher = InboxWatcher(interval: { 300 }, onTick: {
            tickCount += 1
            if tickCount == 1 {
                firstTickStarted.fulfill()
                await withCheckedContinuation { continuation in
                    firstTickContinuation = continuation
                }
            } else if tickCount == 2 {
                secondTickStarted.fulfill()
            }
        })

        watcher.start()
        await fulfillment(of: [firstTickStarted], timeout: 1)

        watcher.stop()
        watcher.start()
        firstTickContinuation?.resume()

        await fulfillment(of: [secondTickStarted], timeout: 1)
        watcher.stop()

        XCTAssertEqual(tickCount, 2)
    }
}
