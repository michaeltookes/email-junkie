import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateConnectionPasswordNormalizationTests: XCTestCase {

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
}
