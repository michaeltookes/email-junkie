import XCTest
@testable import EmailJunkie

@MainActor
final class WatchedFolderTranscriptSourceTests: XCTestCase {

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private let sampleVTT = """
    WEBVTT

    00:00:00.000 --> 00:00:02.000
    <v Dana>Hi there.</v>
    """

    func testDeliversOnlyNewTranscriptFilesAndSkipsPreExisting() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Pre-existing notes.", to: dir.appendingPathComponent("old.txt"))

        var delivered: [IngestedTranscript] = []
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }
        XCTAssertTrue(source.isActive)

        try write(sampleVTT, to: dir.appendingPathComponent("call.vtt"))
        try write("not a transcript", to: dir.appendingPathComponent("video.mp4"))
        await source.scanForNewTranscripts()

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.origin, .watchedFolder)
        XCTAssertEqual(delivered.first?.parsed().text, "Dana: Hi there.")
    }

    func testRescanDoesNotRedeliverProcessedFiles() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        try write("Marcus: recap.", to: dir.appendingPathComponent("one.txt"))
        await source.scanForNewTranscripts()
        await source.scanForNewTranscripts()

        XCTAssertEqual(delivered.count, 1)
    }

    func testRecursiveScanDeliversTranscriptInsideNewSubdirectory() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        let callDir = dir.appendingPathComponent("2026-08-12 14.00.00 Weekly Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: callDir, withIntermediateDirectories: true)
        try write(sampleVTT, to: callDir.appendingPathComponent("call.vtt"))
        await source.scanForNewTranscripts()

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.parsed().text, "Dana: Hi there.")
    }

    func testPreExistingNestedTranscriptIsSeededAsSeen() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let callDir = dir.appendingPathComponent("Existing Call", isDirectory: true)
        try FileManager.default.createDirectory(at: callDir, withIntermediateDirectories: true)
        try write("Marcus: old recap.", to: callDir.appendingPathComponent("old.txt"))

        var delivered: [IngestedTranscript] = []
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        await source.scanForNewTranscripts()

        XCTAssertTrue(delivered.isEmpty)
    }

    // Finding 1(a): a file created empty (mid-write) then gaining content must be
    // delivered exactly once, not permanently dropped.
    func testFileAppearingEmptyThenGainingContentDeliveredExactlyOnce() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        let url = dir.appendingPathComponent("call.vtt")
        try write("", to: url)             // appears empty first
        await source.scanForNewTranscripts()
        XCTAssertTrue(delivered.isEmpty, "An empty (mid-write) file must not be delivered or marked seen")

        try write(sampleVTT, to: url)      // content lands on a later event
        await source.scanForNewTranscripts()
        await source.scanForNewTranscripts()     // and never duplicates afterwards
        XCTAssertEqual(delivered.count, 1)
    }

    // Finding 1(b): a delivery the app can't yet accept (returns false) must be
    // retried on the next scan, then delivered exactly once when accepted.
    func testRejectedDeliveryIsRetriedThenDeliveredOnce() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var ready = false
        var deliveredCount = 0
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { _ in
            guard ready else { return false }
            deliveredCount += 1
            return true
        }
        source.start()
        defer { source.stop() }

        try write("Marcus: recap.", to: dir.appendingPathComponent("call.txt"))
        await source.scanForNewTranscripts()
        XCTAssertEqual(deliveredCount, 0, "Not-ready delivery must be rejected, file left unseen")

        ready = true
        await source.scanForNewTranscripts()
        await source.scanForNewTranscripts()
        XCTAssertEqual(deliveredCount, 1, "Retried once ready, then never duplicated")
    }

    func testRejectedDeliverySchedulesRetryScan() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var ready = false
        var deliveredCount = 0
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.rejectedDeliveryRetryDelayNanoseconds = 1_000_000
        source.onTranscript = { _ in
            guard ready else { return false }
            deliveredCount += 1
            return true
        }
        source.start()
        defer { source.stop() }

        try write("Marcus: recap.", to: dir.appendingPathComponent("call.txt"))
        await source.scanForNewTranscripts()
        XCTAssertEqual(deliveredCount, 0)

        ready = true
        for _ in 0..<100 where deliveredCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(deliveredCount, 1)
    }

    func testInFlightDeliveryIsNotDeliveredTwiceBeforeAccepted() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let started = expectation(description: "delivery started")
        var continuation: CheckedContinuation<Bool, Never>?
        var deliveryCount = 0
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { _ in
            deliveryCount += 1
            started.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }
        source.start()
        defer { source.stop() }

        try write("Marcus: recap.", to: dir.appendingPathComponent("call.txt"))
        let firstScan = Task { await source.scanForNewTranscripts() }
        await fulfillment(of: [started], timeout: 1)
        await source.scanForNewTranscripts()
        XCTAssertEqual(deliveryCount, 1, "A pending delivery must not duplicate before acceptance is known")

        continuation?.resume(returning: true)
        await firstScan.value
        await source.scanForNewTranscripts()
        XCTAssertEqual(deliveryCount, 1, "Accepted files are marked seen only after the async callback completes")
    }

    // Finding 2: a folder that can't be opened must surface an error and leave the
    // source inactive rather than silently claiming to watch.
    func testStartOnMissingFolderSurfacesErrorAndStaysInactive() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        var reported: WatchedFolderError?
        let source = WatchedFolderTranscriptSource(folderURL: missing)
        source.onError = { reported = $0 }
        source.start()

        XCTAssertFalse(source.isActive)
        XCTAssertEqual(reported, .cannotOpenFolder(missing.path))
    }

    func testWatchedFolderErrorMessagesAreUserFacing() {
        XCTAssertTrue(AppState.watchedFolderMessage(for: .cannotOpenFolder("/x")).contains("/x"))
        XCTAssertTrue(AppState.watchedFolderMessage(for: .folderUnavailable("/y")).contains("/y"))
    }

    func testSettingsRoundTripPersistsWatchedFolder() throws {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            transcriptWatchedFolderEnabled: true,
            transcriptWatchedFolderPath: "/Users/me/Zoom"
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.transcriptWatchedFolderEnabled)
        XCTAssertEqual(decoded.transcriptWatchedFolderPath, "/Users/me/Zoom")
    }

    func testOlderSettingsDecodeWatchedFolderOff() throws {
        let json = "{\"schemaVersion\": 12, \"pollIntervalSeconds\": 300}"
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.transcriptWatchedFolderEnabled)
        XCTAssertEqual(decoded.transcriptWatchedFolderPath, "")
    }
}
