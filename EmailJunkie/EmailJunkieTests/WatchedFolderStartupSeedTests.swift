import XCTest
@testable import EmailJunkie

final class WatchedFolderStartupSeedTests: XCTestCase {

    func testIncompleteDiscoveryCannotEstablishInitialBaseline() {
        XCTAssertFalse(WatchedFolderStartupSeed.canEstablishInitialBaseline(discoveryIsComplete: false))
        XCTAssertTrue(WatchedFolderStartupSeed.canEstablishInitialBaseline(discoveryIsComplete: true))
    }

    func testMissingDirectoryAddedDateIsSeededToPreserveHistoricalFiles() {
        let startupBoundary = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(WatchedFolderStartupSeed.existedBeforeStartup(
            addedToDirectoryDate: nil,
            startedAt: startupBoundary
        ))
    }

    func testDirectoryAddedDateDeterminesStartupBaseline() {
        let startupBoundary = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(WatchedFolderStartupSeed.existedBeforeStartup(
            addedToDirectoryDate: startupBoundary.addingTimeInterval(-1),
            startedAt: startupBoundary
        ))
        XCTAssertFalse(WatchedFolderStartupSeed.existedBeforeStartup(
            addedToDirectoryDate: startupBoundary.addingTimeInterval(1),
            startedAt: startupBoundary
        ))
    }
}
