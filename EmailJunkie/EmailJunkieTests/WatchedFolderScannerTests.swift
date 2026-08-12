import XCTest
@testable import EmailJunkie

final class WatchedFolderScannerTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

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

    func testSeenKeyStandardizesPath() {
        XCTAssertEqual(
            WatchedFolderScanner.seenKey(for: url("/calls/one.vtt")),
            "/calls/one.vtt"
        )
    }
}
