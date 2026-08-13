import XCTest
@testable import EmailJunkie

@MainActor
final class WatchedFolderValidatedDeliveryTests: XCTestCase {

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-folder-validated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scanStable(_ source: WatchedFolderTranscriptSource) async {
        await source.scanForNewTranscripts()
        await source.scanForNewTranscripts()
    }

    func testValidatedDeliverySkipsCommitWhenFileChangesDuringCallback() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var attempted: [String] = []
        var committed: [String] = []
        var didAppend = false
        let transcriptURL = dir.appendingPathComponent("transcript.txt")
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.fileStabilityDelayNanoseconds = 0
        source.onTranscriptValidatedDelivery = { transcript, shouldCommit in
            attempted.append(transcript.rawText)
            if !didAppend {
                didAppend = true
                try? self.write(
                    "\(transcript.rawText)\nSecond half.",
                    to: transcriptURL
                )
            }
            guard shouldCommit() else { return .retry }
            committed.append(transcript.rawText)
            return .accepted
        }
        source.start()
        defer { source.stop() }

        try write("First half.", to: transcriptURL)
        await scanStable(source)
        await scanStable(source)

        XCTAssertEqual(attempted, ["First half.", "First half.\nSecond half."])
        XCTAssertEqual(committed, ["First half.\nSecond half."])
    }
}
