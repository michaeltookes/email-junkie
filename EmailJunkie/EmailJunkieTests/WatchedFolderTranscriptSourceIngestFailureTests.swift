import XCTest
@testable import EmailJunkie

@MainActor
final class WatchedFolderIngestFailureTests: XCTestCase {

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-folder-\(UUID().uuidString)", isDirectory: true)
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

    func testUnreadableStableFileRetriesAfterReadAccessIsRestored() async throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [String] = []
        let source = makeSource(folderURL: dir)
        source.loadSeenVersions = { [:] }
        source.onTranscript = { delivered.append($0.rawText); return true }
        source.start()
        defer { source.stop() }

        let url = dir.appendingPathComponent("call.txt")
        try write("Marcus: recap.", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        await scanStable(source)
        XCTAssertTrue(delivered.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        await scanStable(source)

        XCTAssertEqual(delivered, ["Marcus: recap."])
    }
}
