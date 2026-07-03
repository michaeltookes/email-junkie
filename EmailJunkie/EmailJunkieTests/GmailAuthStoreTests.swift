import XCTest
@testable import EmailJunkie

final class GmailAuthStoreTests: XCTestCase {

    private func makeStore() -> (GmailAuthStore, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        return (GmailAuthStore(secrets: secrets), secrets)
    }

    private func sampleToken() -> OAuthToken {
        OAuthToken(
            accessToken: "at",
            refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 2_000_000),
            scope: "s",
            tokenType: "Bearer"
        )
    }

    func testCredentialsRoundTrip() throws {
        let (store, _) = makeStore()
        try store.saveCredentials(GmailCredentials(clientID: "cid", clientSecret: "secret"))
        XCTAssertEqual(try store.loadCredentials(), GmailCredentials(clientID: "cid", clientSecret: "secret"))
    }

    func testSaveCredentialsRestoresPreviousPairWhenSecretWriteFails() throws {
        let secrets = GmailAuthStoreFailingSecretStore(seed: [
            .googleClientID: "old-cid",
            .googleClientSecret: "old-secret"
        ])
        let store = GmailAuthStore(secrets: secrets)
        secrets.failOnSet = .googleClientSecret

        XCTAssertThrowsError(
            try store.saveCredentials(GmailCredentials(clientID: "new-cid", clientSecret: "new-secret"))
        )

        XCTAssertEqual(try store.loadCredentials(), GmailCredentials(clientID: "old-cid", clientSecret: "old-secret"))
    }

    func testSaveCredentialsClearsPartialPairWhenSecretWriteFailsWithoutExistingCredentials() throws {
        let secrets = GmailAuthStoreFailingSecretStore()
        let store = GmailAuthStore(secrets: secrets)
        secrets.failOnSet = .googleClientSecret

        XCTAssertThrowsError(
            try store.saveCredentials(GmailCredentials(clientID: "new-cid", clientSecret: "new-secret"))
        )

        XCTAssertNil(try secrets.value(for: .googleClientID))
        XCTAssertNil(try secrets.value(for: .googleClientSecret))
        XCTAssertNil(try store.loadCredentials())
    }

    func testCredentialsAreNilWhenIncomplete() throws {
        let (store, secrets) = makeStore()
        try secrets.set("only-id", for: .googleClientID)
        XCTAssertNil(try store.loadCredentials())
    }

    func testTokenRoundTrip() throws {
        let (store, _) = makeStore()
        try store.saveToken(sampleToken())
        XCTAssertEqual(try store.loadToken(), sampleToken())
    }

    func testIsConnectedReflectsStoredToken() throws {
        let (store, _) = makeStore()
        XCTAssertFalse(store.isConnected)
        try store.saveToken(sampleToken())
        XCTAssertTrue(store.isConnected)
    }

    func testDeleteTokenLeavesCredentialsIntact() throws {
        let (store, _) = makeStore()
        try store.saveCredentials(GmailCredentials(clientID: "cid", clientSecret: "secret"))
        try store.saveToken(sampleToken())

        try store.deleteToken()

        XCTAssertNil(try store.loadToken())
        XCTAssertFalse(store.isConnected)
        XCTAssertNotNil(try store.loadCredentials(), "disconnect clears the token but keeps BYO credentials")
    }

    func testDeleteCredentialsRemovesThem() throws {
        let (store, _) = makeStore()
        try store.saveCredentials(GmailCredentials(clientID: "cid", clientSecret: "secret"))
        try store.deleteCredentials()
        XCTAssertNil(try store.loadCredentials())
    }
}

private enum GmailAuthStoreSecretError: LocalizedError {
    case saveFailed

    var errorDescription: String? {
        "Unable to save Gmail credentials."
    }
}

private final class GmailAuthStoreFailingSecretStore: SecretStore {
    var failOnSet: SecretKey?
    private var storage: [String: String]

    init(seed: [SecretKey: String] = [:]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        if failOnSet == key {
            throw GmailAuthStoreSecretError.saveFailed
        }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}
