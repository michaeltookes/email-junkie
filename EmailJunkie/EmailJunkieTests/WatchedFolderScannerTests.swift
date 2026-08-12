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
        let result = WatchedFolderScanner.newTranscripts(
            in: [
                url("/calls/old.txt"),        // already seen
                url("/calls/new.vtt"),        // new transcript
                url("/calls/ignore.mp4"),     // not a transcript
                url("/calls/notes.md")        // new transcript
            ],
            alreadySeen: seeded
        )
        XCTAssertEqual(result.new.map(\.lastPathComponent), ["new.vtt", "notes.md"])
        XCTAssertTrue(result.seen.contains("/calls/new.vtt"))
        XCTAssertTrue(result.seen.contains("/calls/notes.md"))
        XCTAssertFalse(result.seen.contains("/calls/ignore.mp4"))
    }

    func testRescanDoesNotRedeliverAlreadyProcessedFiles() {
        let first = WatchedFolderScanner.newTranscripts(
            in: [url("/calls/one.vtt")],
            alreadySeen: []
        )
        XCTAssertEqual(first.new.count, 1)

        let second = WatchedFolderScanner.newTranscripts(
            in: [url("/calls/one.vtt")],
            alreadySeen: first.seen
        )
        XCTAssertTrue(second.new.isEmpty)
    }
}
