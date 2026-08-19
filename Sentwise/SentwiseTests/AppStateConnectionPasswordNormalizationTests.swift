import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateConnectionPasswordTests: XCTestCase {

    private func makeAppState(provider: MailProvider, secrets: SecretStore) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    func testTestConnectionWithGenericCredentialsPreservesInteriorPasswordWhitespace() async {
        let secrets = InMemorySecretStore()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)

        await appState.testConnection(with: MailAccountCredentials(
            email: "me@example.org",
            appPassword: "  correct horse  battery staple  ",
            host: "imap.example.org",
            port: 993
        ))

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(provider.lastCredentials?.appPassword, "correct horse  battery staple")
        XCTAssertEqual(
            try? secrets.value(for: .mailAppPassword(email: "me@example.org")),
            "correct horse  battery staple"
        )
    }

    func testConnectionWithRecognizedEmailAndCustomHostPreservesInteriorPasswordWhitespace() async {
        let secrets = InMemorySecretStore()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)

        await appState.testConnection(with: MailAccountCredentials(
            email: "me@gmail.com",
            appPassword: "  correct horse  battery staple  ",
            host: "imap.proxy.example",
            port: 993
        ))

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(provider.lastCredentials?.appPassword, "correct horse  battery staple")
        XCTAssertEqual(
            try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")),
            "correct horse  battery staple"
        )
    }
}
