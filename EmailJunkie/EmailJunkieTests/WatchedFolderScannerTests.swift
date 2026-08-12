import XCTest
@testable import EmailJunkie

final class WatchedFolderScannerTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSeedSeenFiltersToTranscriptFiles() {
        let seen = WatchedFolderScanner.seedSeen(from: [
            url("/calls/a.vtt"),
            url("/calls/b.mp4"),
            url("/calls/c.srt")
        ])
        XCTAssertEqual(seen, ["/calls/a.vtt", "/calls/c.srt"])
    }

    func testNewTranscriptsReturnsOnlyUnseenTranscriptFiles() {
        let seeded = WatchedFolderScanner.seedSeen(from: [url("/calls/old.txt")])
        let new = WatchedFolderScanner.newTranscripts(
            in: [
                url("/calls/old.txt"),        // already seen
                url("/calls/new.vtt"),        // new transcript
                url("/calls/ignore.mp4"),     // not a transcript
                url("/calls/notes.md")        // new transcript
            ],
            alreadySeen: seeded
        )
        XCTAssertEqual(new.map(\.lastPathComponent), ["new.vtt", "notes.md"])
    }

    func testNewTranscriptsDoesNotCommitSeen() {
        // The scanner never mutates the seen-set — committing a file is the
        // caller's job, done only after a successful ingest+delivery.
        let seen: Set<String> = []
        let first = WatchedFolderScanner.newTranscripts(in: [url("/calls/one.vtt")], alreadySeen: seen)
        let second = WatchedFolderScanner.newTranscripts(in: [url("/calls/one.vtt")], alreadySeen: seen)
        XCTAssertEqual(first.map(\.lastPathComponent), ["one.vtt"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["one.vtt"])
    }

    func testNewTranscriptsTreatsRecreatedPathAsNewVersion() throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("transcript.txt")

        try "First call.".write(to: transcript, atomically: true, encoding: .utf8)
        let seen = WatchedFolderScanner.seedSeenVersions(from: [transcript])
        try FileManager.default.removeItem(at: transcript)
        let recreated = dir.appendingPathComponent("transcript.txt")
        try "Second call with a longer transcript.".write(to: recreated, atomically: true, encoding: .utf8)

        let new = WatchedFolderScanner.newTranscripts(in: [recreated], alreadySeen: seen)

        XCTAssertEqual(new.map(\.lastPathComponent), ["transcript.txt"])
    }

    func testReconcileSeenVersionsPreservesRenamedDirectoryContents() throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalDir = dir.appendingPathComponent("Original", isDirectory: true)
        let renamedDir = dir.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)
        let original = originalDir.appendingPathComponent("transcript.txt")
        try "First call.".write(to: original, atomically: true, encoding: .utf8)
        let seen = WatchedFolderScanner.seedSeenVersions(from: [original])

        try FileManager.default.moveItem(at: originalDir, to: renamedDir)
        let renamed = renamedDir.appendingPathComponent("transcript.txt")
        let reconciled = WatchedFolderScanner.reconcileSeenVersions(seen, with: [renamed])
        let new = WatchedFolderScanner.newTranscripts(in: [renamed], alreadySeen: reconciled)

        XCTAssertTrue(new.isEmpty)
        XCTAssertNotNil(reconciled[WatchedFolderScanner.seenKey(for: renamed)])
        XCTAssertNil(reconciled[WatchedFolderScanner.seenKey(for: original)])
    }

    func testSeenKeyStandardizesPath() {
        XCTAssertEqual(
            WatchedFolderScanner.seenKey(for: url("/calls/one.vtt")),
            "/calls/one.vtt"
        )
    }
}
