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
