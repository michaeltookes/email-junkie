import XCTest
@testable import EmailJunkie

@MainActor
final class WatchedFolderSnapshotValidationTests: XCTestCase {

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-folder-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    #if DEBUG
    func testAppendBeforeDetachedReadDefersUntilUpdatedSnapshotIsStable() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("call.txt")
        var delivered: [String] = []
        var didAppend = false
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.fileStabilityDelayNanoseconds = 0
        source.onBeforeIngestForTesting = { _ in
            guard !didAppend else { return }
            didAppend = true
            if let handle = try? FileHandle(forWritingTo: url) {
                do {
                    try handle.seekToEnd()
                    handle.write(Data("\nSecond half.".utf8))
                    try handle.close()
                } catch {}
            }
        }
        source.onTranscript = {
            delivered.append($0.rawText)
            return true
        }
        source.start()
        defer { source.stop() }

        try write("First half.", to: url)
        await source.scanForNewTranscripts()
        XCTAssertTrue(delivered.isEmpty)

        await source.scanForNewTranscripts()

        XCTAssertEqual(delivered, ["First half.\nSecond half."])
    }
    #endif
}
