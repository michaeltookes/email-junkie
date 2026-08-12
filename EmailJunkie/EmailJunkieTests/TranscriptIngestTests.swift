import XCTest
@testable import EmailJunkie

final class TranscriptIngestTests: XCTestCase {

    func testFromPasteWrapsTextAsPasteOrigin() throws {
        let ingested = try TranscriptIngest.fromPaste("Marcus: hello", format: .plainText)
        XCTAssertEqual(ingested.origin, .paste)
        XCTAssertEqual(ingested.format, .plainText)
        XCTAssertNil(ingested.suggestedTitle)
        XCTAssertEqual(ingested.rawText, "Marcus: hello")
    }

    func testFromPasteRejectsEmpty() {
        XCTAssertThrowsError(try TranscriptIngest.fromPaste("   \n  ")) { error in
            XCTAssertEqual(error as? TranscriptIngestError, .emptyTranscript)
        }
    }

    func testFromFileReadsAndInfersFormatAndTitle() throws {
        let url = try writeTempFile(name: "Sync with Dana.vtt", contents: """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        <v Dana>Hi there.</v>
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let ingested = try TranscriptIngest.fromFile(url)
        XCTAssertEqual(ingested.origin, .file)
        XCTAssertEqual(ingested.format, .webVTT)
        XCTAssertEqual(ingested.suggestedTitle, "Sync with Dana")
        XCTAssertEqual(ingested.parsed().text, "Dana: Hi there.")
    }

    func testFromFileRejectsUnsupportedExtension() throws {
        let url = try writeTempFile(name: "recording.mp4", contents: "not a transcript")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try TranscriptIngest.fromFile(url)) { error in
            XCTAssertEqual(error as? TranscriptIngestError, .unsupportedFormat("mp4"))
        }
    }

    func testFromFileRejectsEmptyFile() throws {
        let url = try writeTempFile(name: "empty.txt", contents: "   \n  ")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try TranscriptIngest.fromFile(url)) { error in
            XCTAssertEqual(error as? TranscriptIngestError, .emptyTranscript)
        }
    }

    private func writeTempFile(name: String, contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
