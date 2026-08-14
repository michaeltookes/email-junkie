import XCTest
@testable import Sentwise

@MainActor
final class WatchedFolderRejectedDeliveryTests: XCTestCase {

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-folder-rejected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSource(folderURL: URL) -> WatchedFolderTranscriptSource {
        let source = WatchedFolderTranscriptSource(folderURL: folderURL)
        source.fileStabilityDelayNanoseconds = 0
        return source
    }

    private func scanStable(_ source: WatchedFolderTranscriptSource) async {
        await source.scanForNewTranscripts()
        await source.scanForNewTranscripts()
    }

    func testRetryableRejectedDeliveryStopsAfterAttemptBudgetAndMarksSeen() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var storedSeen: [String: WatchedFolderFileSnapshot]?
        var deliveredCount = 0
        let source = makeSource(folderURL: dir)
        source.loadSeenVersions = { storedSeen }
        source.onSeenVersionsChanged = {
            storedSeen = $0
            return true
        }
        source.rejectedDeliveryRetryDelayNanoseconds = 0
        source.rejectedDeliveryMaxRetryDelayNanoseconds = 0
        source.rejectedDeliveryMaxAttempts = 2
        source.onTranscriptDelivery = { _ in
            deliveredCount += 1
            return .retry
        }
        source.start()
        defer { source.stop() }

        let url = dir.appendingPathComponent("call.txt")
        try write("Marcus: recap.", to: url)
        await scanStable(source)
        XCTAssertEqual(deliveredCount, 2)
        XCTAssertTrue(storedSeen?.keys.contains(WatchedFolderScanner.seenKey(for: url)) == true)

        await scanStable(source)

        XCTAssertEqual(deliveredCount, 2, "Retryable delivery failures must stop after the attempt cap")
    }

    func testDeferredDeliveryIsNotConsumedByRetryBudget() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var ready = false
        var storedSeen: [String: WatchedFolderFileSnapshot]?
        var deliveredCount = 0
        let source = makeSource(folderURL: dir)
        source.loadSeenVersions = { storedSeen }
        source.onSeenVersionsChanged = {
            storedSeen = $0
            return true
        }
        source.rejectedDeliveryMaxAttempts = 1
        source.onTranscriptDelivery = { _ in
            deliveredCount += 1
            return ready ? .accepted : .deferred
        }
        source.start()
        defer { source.stop() }

        let url = dir.appendingPathComponent("call.txt")
        try write("Marcus: recap.", to: url)
        await scanStable(source)
        await scanStable(source)
        XCTAssertEqual(deliveredCount, 1)
        XCTAssertFalse(storedSeen?.keys.contains(WatchedFolderScanner.seenKey(for: url)) == true)

        ready = true
        source.releaseDeferredDeliveries()
        await scanStable(source)

        XCTAssertEqual(deliveredCount, 2)
        XCTAssertTrue(storedSeen?.keys.contains(WatchedFolderScanner.seenKey(for: url)) == true)
    }
}
