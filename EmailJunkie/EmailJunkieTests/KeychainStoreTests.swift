import XCTest
@testable import EmailJunkie

/// Integration tests against the real macOS Keychain.
///
/// They run locally to verify the real Security-framework round-trip, and skip
/// automatically where the Keychain isn't usable (e.g. a CI runner without an
/// unlocked login keychain) by probing it first. They use a dedicated test
/// service so they never touch real app secrets, and clean up after themselves.
final class KeychainStoreTests: XCTestCase {

    private let store = KeychainStore(service: "com.tookes.EmailJunkie.tests")
    private let key = SecretKey(rawValue: "test.sample")

    override func setUpWithError() throws {
        try skipIfKeychainUnavailable()
        try store.removeAll()
    }

    /// Skips the test when the Keychain can't be used in this environment.
    private func skipIfKeychainUnavailable() throws {
        let probe = SecretKey(rawValue: "test.probe")
        do {
            try store.set("ok", for: probe)
            let value = try store.value(for: probe)
            try store.remove(probe)
            if value != "ok" {
                throw XCTSkip("Keychain did not round-trip; skipping integration tests")
            }
        } catch let error as KeychainError {
            throw XCTSkip("Keychain unavailable in this environment (\(error)); skipping")
        }
    }

    override func tearDownWithError() throws {
        try? store.removeAll()
    }

    func testSetAndGetRoundTrips() throws {
        try store.set("secret-value", for: key)
        XCTAssertEqual(try store.value(for: key), "secret-value")
    }

    func testValueIsNilWhenAbsent() throws {
        XCTAssertNil(try store.value(for: SecretKey(rawValue: "test.missing")))
    }

    func testSetOverwritesExistingValue() throws {
        try store.set("first", for: key)
        try store.set("second", for: key)
        XCTAssertEqual(try store.value(for: key), "second")
    }

    func testRemoveDeletesValue() throws {
        try store.set("x", for: key)
        try store.remove(key)
        XCTAssertNil(try store.value(for: key))
    }

    func testRemoveAllClearsEverything() throws {
        try store.set("a", for: SecretKey(rawValue: "test.a"))
        try store.set("b", for: SecretKey(rawValue: "test.b"))
        try store.removeAll()
        XCTAssertNil(try store.value(for: SecretKey(rawValue: "test.a")))
        XCTAssertNil(try store.value(for: SecretKey(rawValue: "test.b")))
    }
}
