import XCTest
@testable import EmailJunkieMail

final class SmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertTrue(EmailJunkieMail.isLinked)
    }
}
