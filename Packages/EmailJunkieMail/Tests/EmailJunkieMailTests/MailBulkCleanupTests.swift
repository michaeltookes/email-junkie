import XCTest
@testable import EmailJunkieMail

/// Covers the pure selection math behind bulk cleanup (item 42). The windowing
/// is what keeps a bulk operation under NIO-IMAP's 8 KB frame cap on a mailbox
/// of any size, so its boundaries are worth pinning down exactly.
final class MailBulkCleanupTests: XCTestCase {

    // MARK: - Windows

    func testEmptyMailboxHasNoWindows() {
        XCTAssertTrue(SequenceWindow.windows(total: 0).isEmpty)
    }

    func testNegativeTotalHasNoWindows() {
        XCTAssertTrue(SequenceWindow.windows(total: -5).isEmpty)
    }

    func testNonPositiveWindowSizeIsRejectedRatherThanLoopingForever() {
        XCTAssertTrue(SequenceWindow.windows(total: 100, size: 0).isEmpty)
        XCTAssertTrue(SequenceWindow.windows(total: 100, size: -10).isEmpty)
    }

    func testMailboxSmallerThanOneWindowIsASingleFullRange() {
        XCTAssertEqual(
            SequenceWindow.windows(total: 42, size: 500).map(Tuple.init),
            [Tuple(lower: 1, upper: 42)]
        )
    }

    func testWindowsWalkNewestFirst() {
        let windows = SequenceWindow.windows(total: 1200, size: 500).map(Tuple.init)
        XCTAssertEqual(
            windows,
            [
                Tuple(lower: 701, upper: 1200),
                Tuple(lower: 201, upper: 700),
                Tuple(lower: 1, upper: 200),
            ]
        )
    }

    func testWindowsCoverEveryMessageExactlyOnce() {
        for total in [1, 2, 499, 500, 501, 1000, 1001, 7_531] {
            let windows = SequenceWindow.windows(total: total, size: 500)
            let covered = windows.flatMap { Array($0.lower...$0.upper) }.sorted()
            XCTAssertEqual(
                covered,
                Array(1...UInt32(total)),
                "windows must tile 1...\(total) with no gap or overlap"
            )
        }
    }

    func testWindowNeverExceedsRequestedSize() {
        for total in [1, 500, 501, 999, 10_000] {
            for window in SequenceWindow.windows(total: total, size: 500) {
                XCTAssertLessThanOrEqual(window.upper - window.lower + 1, 500)
            }
        }
    }

    func testExactMultipleDoesNotEmitAnEmptyTrailingWindow() {
        let windows = SequenceWindow.windows(total: 1000, size: 500).map(Tuple.init)
        XCTAssertEqual(windows, [Tuple(lower: 501, upper: 1000), Tuple(lower: 1, upper: 500)])
    }

    /// The whole point of windowing: a huge mailbox must still be walked in
    /// bounded slices rather than one unbounded UID SEARCH (item 45).
    func testVeryLargeMailboxStaysBounded() {
        let windows = SequenceWindow.windows(total: 250_000, size: 500)
        XCTAssertEqual(windows.count, 500)
        XCTAssertEqual(windows.first.map(Tuple.init), Tuple(lower: 249_501, upper: 250_000))
        XCTAssertEqual(windows.last.map(Tuple.init), Tuple(lower: 1, upper: 500))
    }

    // MARK: - Batches

    func testNoUIDsProducesNoBatches() {
        XCTAssertTrue(SequenceWindow.batches([]).isEmpty)
    }

    func testBatchesSplitOnSizeAndPreserveOrder() {
        XCTAssertEqual(
            SequenceWindow.batches([1, 2, 3, 4, 5], size: 2),
            [[1, 2], [3, 4], [5]]
        )
    }

    func testBatchesKeepEveryUID() {
        let uids = (1...1_234).map(UInt32.init)
        XCTAssertEqual(SequenceWindow.batches(uids, size: 500).flatMap { $0 }, uids)
    }

    func testNonPositiveBatchSizeIsRejected() {
        XCTAssertTrue(SequenceWindow.batches([1, 2, 3], size: 0).isEmpty)
    }

    // MARK: - Action semantics

    func testMarkReadIsNotDestructiveAndStaysInPlace() {
        XCTAssertFalse(MailBulkAction.markRead.isDestructive)
        XCTAssertNil(MailBulkAction.markRead.destination)
    }

    func testMoveActionsAreDestructiveAndTargetTheRightFolder() {
        XCTAssertTrue(MailBulkAction.archive.isDestructive)
        XCTAssertEqual(MailBulkAction.archive.destination, .archive)

        XCTAssertTrue(MailBulkAction.moveToTrash.isDestructive)
        XCTAssertEqual(MailBulkAction.moveToTrash.destination, .trash)
    }

    /// This slice must never permanently destroy mail — every action is either
    /// in-place or a move to a recoverable folder.
    func testNoActionPermanentlyDeletesMail() {
        for action in MailBulkAction.allCases where action.isDestructive {
            XCTAssertNotNil(
                action.destination,
                "\(action) is destructive but has no destination folder — that would mean expunge"
            )
        }
    }

    // MARK: - Progress

    func testProgressFractionHandlesZeroTotal() {
        XCTAssertEqual(MailBulkProgress(processed: 0, total: 0).fraction, 0)
    }

    func testProgressFractionIsClampedToOne() {
        XCTAssertEqual(MailBulkProgress(processed: 500, total: 100).fraction, 1)
    }

    func testProgressFractionMidway() {
        XCTAssertEqual(MailBulkProgress(processed: 25, total: 100).fraction, 0.25, accuracy: 0.0001)
    }

    /// `(UInt32, UInt32)` tuples are not `Equatable`, so wrap them for assertions.
    private struct Tuple: Equatable {
        var lower: UInt32
        var upper: UInt32

        init(lower: UInt32, upper: UInt32) {
            self.lower = lower
            self.upper = upper
        }

        init(_ window: (lower: UInt32, upper: UInt32)) {
            self.lower = window.lower
            self.upper = window.upper
        }
    }
}
