import XCTest
@testable import Sentwise

final class ProwlHuntRuntimeTests: XCTestCase {

    func testEnablesFromEnvironmentFlag() {
        XCTAssertTrue(ProwlHuntRuntime.isEnabled(
            environment: [ProwlHuntRuntime.environmentKey: "1"],
            arguments: [],
            bundlePath: "/Applications/Sentwise.app"
        ))
    }

    func testEnablesFromLaunchArgument() {
        XCTAssertTrue(ProwlHuntRuntime.isEnabled(
            environment: [:],
            arguments: ["Sentwise", ProwlHuntRuntime.launchArgument],
            bundlePath: "/Applications/Sentwise.app"
        ))
    }

    func testEnablesFromXCTestConfiguration() {
        XCTAssertTrue(ProwlHuntRuntime.isEnabled(
            environment: [ProwlHuntRuntime.xctestConfigurationEnvironmentKey: "/tmp/SentwiseTests.xctestconfiguration"],
            arguments: [],
            bundlePath: "/Applications/Sentwise.app"
        ))
    }

    func testEnablesFromDocumentedProwlDerivedDataBundlePath() {
        XCTAssertTrue(ProwlHuntRuntime.isEnabled(
            environment: [:],
            arguments: [],
            bundlePath: "/repo/.prowl/DerivedData/Build/Products/Debug/Sentwise.app"
        ))
    }

    func testDoesNotEnableForRegularDerivedDataBundlePath() {
        XCTAssertFalse(ProwlHuntRuntime.isEnabled(
            environment: [:],
            arguments: [],
            bundlePath: "/Users/me/Library/Developer/Xcode/DerivedData/Sentwise.app"
        ))
    }

    func testProwlRuntimeUsesIsolatedStoresAndDisablesStartupSideEffects() {
        let runtime = ProwlHuntRuntime(isEnabled: true)

        XCTAssertFalse(runtime.allowsStartupSideEffects)
        XCTAssertFalse(runtime.shouldOpenOnboardingAtLaunch)
        XCTAssertTrue(runtime.makePersistenceProvider() is MemoryPersistenceProvider)
        XCTAssertTrue(runtime.makeSecretStore() is InMemorySecretStore)
    }

    func testProductionRuntimeUsesLiveStoresAndStartupSideEffects() {
        let runtime = ProwlHuntRuntime(isEnabled: false)

        XCTAssertTrue(runtime.allowsStartupSideEffects)
        XCTAssertTrue(runtime.shouldOpenOnboardingAtLaunch)
        XCTAssertFalse(runtime.makePersistenceProvider() is MemoryPersistenceProvider)
        XCTAssertTrue(runtime.makeSecretStore() is KeychainStore)
    }
}
