import XCTest
@testable import EmailJunkie

@MainActor
final class WatchedFolderSeenPersistenceTests: XCTestCase {

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-folder-persistence-\(UUID().uuidString)", isDirectory: true)
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

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition())
    }

    #if DEBUG
    func testStopAfterAsyncDiscoveryDoesNotPublishSeenSnapshotsOrDeliver() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("old.txt")
        try write("Marcus: old recap.", to: transcript)
        let key = WatchedFolderScanner.seenKey(for: transcript)

        var delivered: [String] = []
        var storedSeen: [String: WatchedFolderFileSnapshot]? = WatchedFolderScanner.seedSeenVersions(from: [transcript])
        var persistedSeen = storedSeen
        let source = makeSource(folderURL: dir)
        source.loadSeenVersions = { storedSeen }
        source.onSeenVersionsChanged = {
            storedSeen = $0
            persistedSeen = $0
            return true
        }
        source.onTranscript = { delivered.append($0.rawText); return true }
        source.start()
        defer { source.stop() }

        await source.scanForNewTranscripts()
        XCTAssertNotNil(persistedSeen?[key])
        try FileManager.default.removeItem(at: transcript)
        source.onAfterScanDiscoveryForTesting = {
            source.stop()
        }
        await source.scanForNewTranscripts()

        XCTAssertFalse(source.isActive)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertNotNil(persistedSeen?[key])
    }

    func testInitialStartupSeedWaitsForBaselinePersistence() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Marcus: old recap.", to: dir.appendingPathComponent("old.txt"))
        let newTranscript = dir.appendingPathComponent("new.txt")

        var saveAttempts = 0
        var seedCompleted = false
        var deliveriesBeforeSeed = 0
        let source = makeSource(folderURL: dir)
        source.recursiveRescanDelayNanoseconds = 1_000_000
        source.loadSeenVersions = { nil }
        source.onSeenVersionsChanged = { _ in
            saveAttempts += 1
            if saveAttempts == 1 {
                try? self.write("Marcus: new recap.", to: newTranscript)
                return false
            }
            return true
        }
        source.onAfterSeedSeenForTesting = {
            seedCompleted = true
        }
        source.onTranscript = { _ in
            if !seedCompleted {
                deliveriesBeforeSeed += 1
            }
            return true
        }
        source.start()
        defer { source.stop() }

        try await waitFor { seedCompleted }

        XCTAssertGreaterThanOrEqual(saveAttempts, 2)
        XCTAssertEqual(deliveriesBeforeSeed, 0)
    }
    #endif

    func testAcceptedTranscriptRetriesSeenPersistenceWithoutRedelivery() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var allowPersist = true
        var saveAttempts = 0
        var persistedSeen: [String: WatchedFolderFileSnapshot]?
        var delivered: [String] = []
        let source = makeSource(folderURL: dir)
        source.seenPersistenceRetryDelayNanoseconds = 1_000_000
        source.onSeenVersionsChanged = { snapshots in
            saveAttempts += 1
            guard allowPersist else { return false }
            persistedSeen = snapshots
            return true
        }
        source.onTranscript = { delivered.append($0.rawText); return true }
        source.start()
        defer { source.stop() }

        await source.scanForNewTranscripts()
        allowPersist = false
        let transcript = dir.appendingPathComponent("call.txt")
        try write("Marcus: recap.", to: transcript)
        let key = WatchedFolderScanner.seenKey(for: transcript)
        await scanStable(source)

        XCTAssertEqual(delivered, ["Marcus: recap."])
        XCTAssertNil(persistedSeen?[key])
        let failedAttempts = saveAttempts

        await scanStable(source)
        XCTAssertEqual(delivered, ["Marcus: recap."])

        allowPersist = true
        try await waitFor { persistedSeen?[key] != nil }

        XCTAssertEqual(delivered, ["Marcus: recap."])
        XCTAssertGreaterThan(saveAttempts, failedAttempts)
    }
}
