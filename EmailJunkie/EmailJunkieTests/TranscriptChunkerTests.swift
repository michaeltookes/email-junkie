import XCTest
@testable import EmailJunkie

final class TranscriptChunkerTests: XCTestCase {

    func testShortTextIsOneTrimmedChunk() {
        let chunks = TranscriptChunker.chunk("  Hello there  ", maxChars: 100)
        XCTAssertEqual(chunks, ["Hello there"])
    }

    func testEmptyTextProducesNoChunks() {
        XCTAssertTrue(TranscriptChunker.chunk("   \n\n  ", maxChars: 100).isEmpty)
    }

    func testSplitsOnLineBoundariesWithinLimit() {
        let text = (1...10).map { "Speaker: turn number \($0)" }.joined(separator: "\n")
        let chunks = TranscriptChunker.chunk(text, maxChars: 40)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 40)
        }
        // No content is lost across the split.
        let rejoined = chunks.joined(separator: "\n")
        XCTAssertEqual(rejoined, text)
    }

    func testOverLongSingleLineIsHardSplit() {
        let longLine = String(repeating: "a", count: 250)
        let chunks = TranscriptChunker.chunk(longLine, maxChars: 100)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.count), [100, 100, 50])
    }

    func testNonPositiveMaxCharsReturnsWholeText() {
        XCTAssertEqual(TranscriptChunker.chunk("abc", maxChars: 0), ["abc"])
    }
}
