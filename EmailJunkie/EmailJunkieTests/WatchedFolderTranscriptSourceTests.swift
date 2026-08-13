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

    private func makeSource(folderURL: URL, stabilityDelayNanoseconds: UInt64 = 0)
        -> WatchedFolderTranscriptSource {
        let source = WatchedFolderTranscriptSource(folderURL: folderURL)
        source.fileStabilityDelayNanoseconds = stabilityDelayNanoseconds
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
        let source = makeSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }
        XCTAssertTrue(source.isActive)

        try write(sampleVTT, to: dir.appendingPathComponent("call.vtt"))
        try write("not a transcript", to: dir.appendingPathComponent("video.mp4"))
        await scanStable(source)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.origin, .watchedFolder)
        XCTAssertEqual(delivered.first?.parsed().text, "Dana: Hi there.")
    }

    func testRescanDoesNotRedeliverProcessedFiles() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = makeSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        try write("Marcus: recap.", to: dir.appendingPathComponent("one.txt"))
        await scanStable(source)
        await scanStable(source)

        XCTAssertEqual(delivered.count, 1)
    }

    func testRecreatedProcessedPathDeliversAgain() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [String] = []
        let source = makeSource(folderURL: dir)
        source.onTranscript = { delivered.append($0.rawText); return true }
        source.start()
        defer { source.stop() }

        let transcript = dir.appendingPathComponent("transcript.txt")
        try write("First call.", to: transcript)
        await scanStable(source)

        try FileManager.default.removeItem(at: transcript)
        await scanStable(source)
        try write("Second call with a longer transcript.", to: transcript)
        await scanStable(source)

        XCTAssertEqual(delivered, ["First call.", "Second call with a longer transcript."])
    }

    func testRenamedDirectoryDoesNotRedeliverProcessedFile() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [String] = []
        let source = makeSource(folderURL: dir)
        source.onTranscript = { delivered.append($0.rawText); return true }
        source.start()
        defer { source.stop() }

        let originalDir = dir.appendingPathComponent("Original", isDirectory: true)
        let renamedDir = dir.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)
        try write("First call.", to: originalDir.appendingPathComponent("transcript.txt"))
        await scanStable(source)

        try FileManager.default.moveItem(at: originalDir, to: renamedDir)
        await scanStable(source)

        XCTAssertEqual(delivered, ["First call."])
    }

    func testAppendDuringAcceptedDeliveryLeavesNewVersionPending() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [String] = []
        var didAppend = false
        let source = makeSource(folderURL: dir)
        source.onTranscript = { transcript in
            delivered.append(transcript.rawText)
            if !didAppend {
                didAppend = true
                try? self.write(
                    "\(transcript.rawText)\nSecond half.",
                    to: dir.appendingPathComponent("transcript.txt")
                )
            }
            return true
        }
        source.start()
        defer { source.stop() }

        try write("First half.", to: dir.appendingPathComponent("transcript.txt"))
        await scanStable(source)
        await scanStable(source)

        XCTAssertEqual(delivered, ["First half.", "First half.\nSecond half."])
    }

    func testRecursiveScanDeliversTranscriptInsideNewSubdirectory() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = makeSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        let callDir = dir.appendingPathComponent("2026-08-12 14.00.00 Weekly Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: callDir, withIntermediateDirectories: true)
        try write(sampleVTT, to: callDir.appendingPathComponent("call.vtt"))
        await scanStable(source)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.parsed().text, "Dana: Hi there.")
    }

    func testPeriodicRecursiveScanDeliversTranscriptInsideExistingSubdirectory() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let callDir = dir.appendingPathComponent("Existing Call", isDirectory: true)
        try FileManager.default.createDirectory(at: callDir, withIntermediateDirectories: true)

        var delivered: [IngestedTranscript] = []
        let source = makeSource(folderURL: dir)
        source.recursiveRescanDelayNanoseconds = 1_000_000
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        try write(sampleVTT, to: callDir.appendingPathComponent("call.vtt"))

        try await waitFor { delivered.count == 1 }
        XCTAssertEqual(delivered.first?.parsed().text, "Dana: Hi there.")
    }

    func testPreExistingNestedTranscriptIsSeededAsSeen() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let callDir = dir.appendingPathComponent("Existing Call", isDirectory: true)
        try FileManager.default.createDirectory(at: callDir, withIntermediateDirectories: true)
        try write("Marcus: old recap.", to: callDir.appendingPathComponent("old.txt"))

        var delivered: [IngestedTranscript] = []
        let source = makeSource(folderURL: dir)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        await scanStable(source)

        XCTAssertTrue(delivered.isEmpty)
    }

    func testPartialWriteWaitsForStableFileBeforeDelivery() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = makeSource(folderURL: dir, stabilityDelayNanoseconds: 200_000_000)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        let url = dir.appendingPathComponent("call.txt")
        try write("Marcus: partial", to: url)
        await source.scanForNewTranscripts()
        XCTAssertTrue(delivered.isEmpty, "A newly observed file must not deliver before the stability delay")

        try write("Marcus: complete recap.", to: url)
        await source.scanForNewTranscripts()
        try await Task.sleep(nanoseconds: 250_000_000)
        await source.scanForNewTranscripts()

        XCTAssertEqual(delivered.map(\.rawText), ["Marcus: complete recap."])
    }

    #if DEBUG
    func testStartCatchUpDeliversFileCreatedAfterStartupSeed() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = makeSource(folderURL: dir)
        source.onAfterSeedSeenForTesting = {
            try? self.write("Marcus: startup recap.", to: dir.appendingPathComponent("call.txt"))
        }
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        try await waitFor { delivered.count == 1 }
        XCTAssertEqual(delivered.first?.rawText, "Marcus: startup recap.")
    }
    #endif

    // Finding 1(a): a file created empty (mid-write) then gaining content must be
    // delivered exactly once, not permanently dropped.
    func testFileAppearingEmptyThenGainingContentDeliveredExactlyOnce() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = makeSource(folderURL: dir, stabilityDelayNanoseconds: 1_000_000)
        source.onTranscript = { delivered.append($0); return true }
        source.start()
        defer { source.stop() }

        let url = dir.appendingPathComponent("call.vtt")
        try write("", to: url)             // appears empty first
        await scanStable(source)
        XCTAssertTrue(delivered.isEmpty, "An empty (mid-write) file must not be delivered or marked seen")

        try write(sampleVTT, to: url)      // content lands on a later event
        try await waitFor { delivered.count == 1 }
        await scanStable(source)           // and never duplicates afterwards
        XCTAssertEqual(delivered.count, 1)
    }

    func testStableEmptyFileWaitsForChangeBeforeRetryingIngest() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [String] = []
        let source = makeSource(folderURL: dir)
        source.onTranscript = { delivered.append($0.rawText); return true }
        source.start()
        defer { source.stop() }

        let url = dir.appendingPathComponent("call.txt")
        try write("", to: url)
        await scanStable(source)
        await scanStable(source)
        XCTAssertTrue(delivered.isEmpty)

        try write("Marcus: recap.", to: url)
        await scanStable(source)

        XCTAssertEqual(delivered, ["Marcus: recap."])
    }

    // Finding 1(b): a delivery the app can't yet accept (returns false) must be
    // retried on the next scan, then delivered exactly once when accepted.
    func testRejectedDeliveryIsRetriedThenDeliveredOnce() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var ready = false
        var deliveredCount = 0
        let source = makeSource(folderURL: dir)
        source.onTranscript = { _ in
            guard ready else { return false }
            deliveredCount += 1
            return true
        }
        source.start()
        defer { source.stop() }

        try write("Marcus: recap.", to: dir.appendingPathComponent("call.txt"))
        await scanStable(source)
        XCTAssertEqual(deliveredCount, 0, "Not-ready delivery must be rejected, file left unseen")

        ready = true
        await scanStable(source)
        await scanStable(source)
        XCTAssertEqual(deliveredCount, 1, "Retried once ready, then never duplicated")
    }

    func testRejectedDeliverySchedulesRetryScan() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var ready = false
        var deliveredCount = 0
        let source = makeSource(folderURL: dir)
        source.rejectedDeliveryRetryDelayNanoseconds = 1_000_000
        source.onTranscriptDelivery = { _ in
            guard ready else { return .retry }
            deliveredCount += 1
            return .accepted
        }
        source.start()
        defer { source.stop() }

        try write("Marcus: recap.", to: dir.appendingPathComponent("call.txt"))
        await scanStable(source)
        XCTAssertEqual(deliveredCount, 0)

        ready = true
        try await waitFor { deliveredCount == 1 }
    }

    func testRejectedDeliveryRemainsPendingAcrossRestartWithPersistedBaseline() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Marcus: old recap.", to: dir.appendingPathComponent("old.txt"))

        var storedSeen: [String: WatchedFolderFileSnapshot]?
        let firstSource = makeSource(folderURL: dir)
        firstSource.loadSeenVersions = { storedSeen }
        firstSource.onSeenVersionsChanged = {
            storedSeen = $0
            return true
        }
        firstSource.onTranscript = { _ in false }
        firstSource.start()
        defer { firstSource.stop() }

        try write("Marcus: pending recap.", to: dir.appendingPathComponent("call.txt"))
        await scanStable(firstSource)
        XCTAssertFalse(storedSeen?.keys.contains { $0.hasSuffix("/call.txt") } ?? true)

        firstSource.stop()
        var delivered: [String] = []
        let restartedSource = makeSource(folderURL: dir)
        restartedSource.loadSeenVersions = { storedSeen }
        restartedSource.onSeenVersionsChanged = {
            storedSeen = $0
            return true
        }
        restartedSource.onTranscript = {
            delivered.append($0.rawText)
            return true
        }
        restartedSource.start()
        defer { restartedSource.stop() }

        await scanStable(restartedSource)

        XCTAssertEqual(delivered, ["Marcus: pending recap."])
    }

    func testOverlappingScansDoNotProcessDifferentCandidatesConcurrently() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Marcus: first.", to: dir.appendingPathComponent("a.txt"))
        try write("Dana: second.", to: dir.appendingPathComponent("b.txt"))

        let started = expectation(description: "first delivery started")
        var continuation: CheckedContinuation<Bool, Never>?
        var delivered: [String] = []
        let source = makeSource(folderURL: dir)
        source.loadSeenVersions = { [:] }
        source.onTranscript = { ingested in
            delivered.append(ingested.rawText)
            if delivered.count == 1 {
                started.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
            return true
        }
        source.start()
        defer { source.stop() }

        await fulfillment(of: [started], timeout: 1)
        await source.scanForNewTranscripts()
        XCTAssertEqual(delivered, ["Marcus: first."])

        continuation?.resume(returning: true)
        try await waitFor { delivered.count == 2 }
        XCTAssertEqual(delivered, ["Marcus: first.", "Dana: second."])
    }

    func testInFlightDeliveryIsNotDeliveredTwiceBeforeAccepted() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Marcus: recap.", to: dir.appendingPathComponent("call.txt"))

        let started = expectation(description: "delivery started")
        var continuation: CheckedContinuation<Bool, Never>?
        var deliveryCount = 0
        let source = makeSource(folderURL: dir)
        source.loadSeenVersions = { [:] }
        source.onTranscript = { _ in
            deliveryCount += 1
            if deliveryCount == 1 {
                started.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
            return true
        }
        source.start()
        defer { source.stop() }

        await fulfillment(of: [started], timeout: 1)
        await source.scanForNewTranscripts()
        XCTAssertEqual(deliveryCount, 1, "A pending delivery must not duplicate before acceptance is known")

        continuation?.resume(returning: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        await source.scanForNewTranscripts()
        XCTAssertEqual(deliveryCount, 1, "Accepted files are marked seen only after the async callback completes")
    }

    func testStopDuringDeliveryPreventsFurtherCandidateProcessing() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [String] = []
        let source = makeSource(folderURL: dir)
        source.onTranscript = { ingested in
            delivered.append(ingested.rawText)
            if delivered.count == 1 {
                source.stop()
            }
            return true
        }
        source.start()
        defer { source.stop() }
        try write("Marcus: first.", to: dir.appendingPathComponent("a.txt"))
        try write("Dana: second.", to: dir.appendingPathComponent("b.txt"))
        await source.scanForNewTranscripts()
        await source.scanForNewTranscripts()

        XCTAssertEqual(delivered, ["Marcus: first."])
    }

    // Finding 2: a folder that can't be opened must surface an error and leave the
    // source inactive rather than silently claiming to watch.
    func testStartOnMissingFolderSurfacesErrorAndStaysInactive() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        var reported: WatchedFolderError?
        let source = makeSource(folderURL: missing)
        source.onError = { reported = $0 }
        source.start()

        XCTAssertFalse(source.isActive)
        XCTAssertEqual(reported, .cannotOpenFolder(missing.path))
    }

    func testWatchedFolderErrorMessagesAreUserFacing() {
        XCTAssertTrue(AppState.watchedFolderMessage(for: .cannotOpenFolder("/x")).contains("/x"))
        XCTAssertTrue(AppState.watchedFolderMessage(for: .folderUnavailable("/y")).contains("/y"))
    }

}
