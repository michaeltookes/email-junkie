import XCTest
@testable import EmailJunkie

/// Behavior tests for the `SecretStore` contract, exercised via the
/// deterministic in-memory implementation so they run anywhere (including CI).
final class SecretStoreTests: XCTestCase {

    func testSetAndGetRoundTrips() throws {
        let store = InMemorySecretStore()
        try store.set("token-123", for: .gmailAccessToken)
        XCTAssertEqual(try store.value(for: .gmailAccessToken), "token-123")
    }

    func testValueIsNilWhenAbsent() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.value(for: .gmailRefreshToken))
    }

    func testSetOverwritesExistingValue() throws {
        let store = InMemorySecretStore()
        try store.set("old", for: .googleClientSecret)
        try store.set("new", for: .googleClientSecret)
        XCTAssertEqual(try store.value(for: .googleClientSecret), "new")
    }

    func testRemoveDeletesValue() throws {
        let store = InMemorySecretStore()
        try store.set("x", for: .gmailAccessToken)
        try store.remove(.gmailAccessToken)
        XCTAssertNil(try store.value(for: .gmailAccessToken))
    }

    func testRemoveAllClearsEverything() throws {
        let store = InMemorySecretStore()
        try store.set("a", for: .gmailAccessToken)
        try store.set("b", for: .gmailRefreshToken)
        try store.removeAll()
        XCTAssertNil(try store.value(for: .gmailAccessToken))
        XCTAssertNil(try store.value(for: .gmailRefreshToken))
    }

    func testSeededStoreExposesInitialValues() throws {
        let store = InMemorySecretStore(seed: [.gmailAccessToken: "seeded"])
        XCTAssertEqual(try store.value(for: .gmailAccessToken), "seeded")
    }

    func testHasValueReflectsPresenceAndEmptiness() throws {
        let store = InMemorySecretStore()
        XCTAssertFalse(store.hasValue(for: .gmailAccessToken))
        try store.set("", for: .gmailAccessToken)
        XCTAssertFalse(store.hasValue(for: .gmailAccessToken), "empty string is not a value")
        try store.set("real", for: .gmailAccessToken)
        XCTAssertTrue(store.hasValue(for: .gmailAccessToken))
    }

    func testLLMAPIKeyIsProviderScoped() {
        XCTAssertEqual(SecretKey.llmAPIKey(provider: "anthropic").rawValue, "llm.anthropic.apiKey")
        XCTAssertNotEqual(
            SecretKey.llmAPIKey(provider: "anthropic"),
            SecretKey.llmAPIKey(provider: "openai")
        )
    }
}
