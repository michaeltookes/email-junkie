import XCTest
@testable import EmailJunkieMail

/// Tests the pure sequence-number paging math behind the bounded "recent mail"
/// view (item 45) — no network.
final class SequencePageRangeTests: XCTestCase {

    // MARK: - forPage

    func testNewestPageIsTheHighestSequenceRange() {
        // 30 messages, first page of 25, newest first → sequences 6...30.
        let range = SequencePageRange.forPage(total: 30, offset: 0, limit: 25)
        XCTAssertEqual(range?.lower, 6)
        XCTAssertEqual(range?.upper, 30)
    }

    func testSecondPagePicksUpBelowTheFirst() {
        // Offset 25 into 30 → the remaining 5 oldest: sequences 1...5.
        let range = SequencePageRange.forPage(total: 30, offset: 25, limit: 25)
        XCTAssertEqual(range?.lower, 1)
        XCTAssertEqual(range?.upper, 5)
    }

    func testPageSmallerThanLimitReturnsWholeMailbox() {
        let range = SequencePageRange.forPage(total: 5, offset: 0, limit: 25)
        XCTAssertEqual(range?.lower, 1)
        XCTAssertEqual(range?.upper, 5)
    }

    func testExactlyOnePageLeavesNoRemainder() {
        let range = SequencePageRange.forPage(total: 25, offset: 0, limit: 25)
        XCTAssertEqual(range?.lower, 1)
        XCTAssertEqual(range?.upper, 25)
        XCTAssertFalse(SequencePageRange.hasMore(total: 25, offset: 0, limit: 25))
    }

    func testEmptyMailboxHasNoRange() {
        XCTAssertNil(SequencePageRange.forPage(total: 0, offset: 0, limit: 25))
    }

    func testOffsetPastTheEndHasNoRange() {
        XCTAssertNil(SequencePageRange.forPage(total: 30, offset: 30, limit: 25))
        XCTAssertNil(SequencePageRange.forPage(total: 30, offset: 40, limit: 25))
    }

    func testNonPositiveLimitOrNegativeOffsetHasNoRange() {
        XCTAssertNil(SequencePageRange.forPage(total: 30, offset: 0, limit: 0))
        XCTAssertNil(SequencePageRange.forPage(total: 30, offset: -1, limit: 25))
    }

    // MARK: - hasMore

    func testHasMoreWhenPagesRemain() {
        XCTAssertTrue(SequencePageRange.hasMore(total: 30, offset: 0, limit: 25))
        XCTAssertFalse(SequencePageRange.hasMore(total: 30, offset: 25, limit: 25))
        XCTAssertFalse(SequencePageRange.hasMore(total: 30, offset: 5, limit: 25))
    }
}
