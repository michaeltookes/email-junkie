import XCTest
@testable import EmailJunkie

/// Unit tests for the `Settings` model.
///
/// These are intentionally small — they exist so the CI pipeline has a real
/// test target to run and a place for future logic tests (voice profile,
/// stale-thread detection, provider selection, etc.) to live.
final class SettingsTests: XCTestCase {

    func testDefaultUsesCurrentSchemaVersion() {
        XCTAssertEqual(Settings.default.schemaVersion, Settings.currentSchemaVersion)
    }

    func testDefaultPollIntervalIsFiveMinutes() {
        XCTAssertEqual(Settings.default.pollIntervalSeconds, 300)
    }

    func testValidatedClampsPollIntervalBelowMinimum() {
        let settings = Settings(schemaVersion: 1, pollIntervalSeconds: 5).validated()
        XCTAssertEqual(settings.pollIntervalSeconds, 30)
    }

    func testValidatedClampsPollIntervalAboveMaximum() {
        let settings = Settings(schemaVersion: 1, pollIntervalSeconds: 100_000).validated()
        XCTAssertEqual(settings.pollIntervalSeconds, 3600)
    }

    func testValidatedKeepsInRangeValueUnchanged() {
        let settings = Settings(schemaVersion: 1, pollIntervalSeconds: 120).validated()
        XCTAssertEqual(settings.pollIntervalSeconds, 120)
    }

    func testSettingsRoundTripsThroughCodable() throws {
        let original = Settings(
            schemaVersion: 1,
            pollIntervalSeconds: 240,
            llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testLegacyFileWithoutLLMKeysDecodesToDefaults() throws {
        // A pre-v3 settings file has no llm keys; they must decode to defaults.
        let legacy = #"{"schemaVersion":2,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.llmProvider, "anthropic")
        XCTAssertEqual(decoded.llmModel, "")
        XCTAssertEqual(decoded.llmVerifiedModel, "")
    }

    func testCurrentSchemaVersionIsSix() {
        XCTAssertEqual(Settings.currentSchemaVersion, 6)
    }

    func testLegacyFileWithoutOnboardingFlagDecodesToNotCompleted() throws {
        // A pre-v6 settings file has no onboarding key; it must decode to false
        // so the flow can run (and be reconciled for already-configured users).
        let legacy = #"{"schemaVersion":5,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.onboardingCompleted)
    }

    func testOnboardingFlagRoundTripsThroughCodable() throws {
        let original = Settings(schemaVersion: 6, pollIntervalSeconds: 300, onboardingCompleted: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.onboardingCompleted)
    }
}
