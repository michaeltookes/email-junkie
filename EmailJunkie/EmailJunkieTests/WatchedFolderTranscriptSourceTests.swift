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

    func testDeliversOnlyNewTranscriptFilesAndSkipsPreExisting() throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Pre-existing notes.", to: dir.appendingPathComponent("old.txt"))

        var delivered: [IngestedTranscript] = []
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { delivered.append($0) }
        source.start()
        defer { source.stop() }

        // Files appearing after start are what should trigger.
        try write("""
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        <v Dana>Hi there.</v>
        """, to: dir.appendingPathComponent("call.vtt"))
        try write("not a transcript", to: dir.appendingPathComponent("video.mp4"))

        source.scanForNewTranscripts()

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.origin, .watchedFolder)
        XCTAssertEqual(delivered.first?.format, .webVTT)
        XCTAssertEqual(delivered.first?.parsed().text, "Dana: Hi there.")
    }

    func testRescanDoesNotRedeliverProcessedFiles() throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        var delivered: [IngestedTranscript] = []
        let source = WatchedFolderTranscriptSource(folderURL: dir)
        source.onTranscript = { delivered.append($0) }
        source.start()
        defer { source.stop() }

        try write("Marcus: recap.", to: dir.appendingPathComponent("one.txt"))
        source.scanForNewTranscripts()
        source.scanForNewTranscripts()

        XCTAssertEqual(delivered.count, 1)
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
