import XCTest
@testable import EmailJunkie

/// Behavior tests for the `SecretStore` contract, exercised via the
/// deterministic in-memory implementation so they run anywhere (including CI).
final class SecretStoreTests: XCTestCase {

    func testSetAndGetRoundTrips() throws {
        let store = InMemorySecretStore()
        try store.set("token-123", for: .gmailToken)
        XCTAssertEqual(try store.value(for: .gmailToken), "token-123")
    }

    func testValueIsNilWhenAbsent() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.value(for: .googleClientID))
    }

    func testSetOverwritesExistingValue() throws {
        let store = InMemorySecretStore()
        try store.set("old", for: .googleClientSecret)
        try store.set("new", for: .googleClientSecret)
        XCTAssertEqual(try store.value(for: .googleClientSecret), "new")
    }

    func testRemoveDeletesValue() throws {
        let store = InMemorySecretStore()
        try store.set("x", for: .gmailToken)
        try store.remove(.gmailToken)
        XCTAssertNil(try store.value(for: .gmailToken))
    }

    func testRemoveAllClearsEverything() throws {
        let store = InMemorySecretStore()
        try store.set("a", for: .gmailToken)
        try store.set("b", for: .googleClientID)
        try store.removeAll()
        XCTAssertNil(try store.value(for: .gmailToken))
        XCTAssertNil(try store.value(for: .googleClientID))
    }

    func testSeededStoreExposesInitialValues() throws {
        let store = InMemorySecretStore(seed: [.gmailToken: "seeded"])
        XCTAssertEqual(try store.value(for: .gmailToken), "seeded")
    }

    func testHasValueReflectsPresenceAndEmptiness() throws {
        let store = InMemorySecretStore()
        XCTAssertFalse(store.hasValue(for: .gmailToken))
        try store.set("", for: .gmailToken)
        XCTAssertFalse(store.hasValue(for: .gmailToken), "empty string is not a value")
        try store.set("real", for: .gmailToken)
        XCTAssertTrue(store.hasValue(for: .gmailToken))
    }

    func testLLMAPIKeyIsProviderScoped() {
        XCTAssertEqual(SecretKey.llmAPIKey(provider: "anthropic").rawValue, "llm.anthropic.apiKey")
        XCTAssertNotEqual(
            SecretKey.llmAPIKey(provider: "anthropic"),
            SecretKey.llmAPIKey(provider: "openai")
        )
    }
}
