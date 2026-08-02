import EmailJunkieMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateSkippedMessageFollowUpTests: XCTestCase {

    private func message(id: UInt32, from: String = "alice@x.com") -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 7,
            from: MailAddress(name: "Alice", email: from),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@x.com>"
        )
    }

    private func baselineProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        return processed
    }

    private func makeAppState(
        fetch: Result<[MailMessage], MailError>,
        header: Result<MailHeaderFields, MailError> = .success(MailHeaderFields())
    ) -> (AppState, FakeAppMailProvider, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            processedMessages: baselineProcessed()
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: .success(Data("Please advise.".utf8)),
            headerResult: header
        )
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "On it.")))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        return (appState, provider, persistence)
    }

    func testEvictedSkipIdentitySuppressesRepeatHeaderFetches() async throws {
        let messages = (1...101).map { message(id: UInt32($0)) }
        let (appState, provider, _) = makeAppState(
            fetch: .success(messages),
            header: .success(MailHeaderFields(listUnsubscribe: "<mailto:unsub@x.com>"))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()
        let evicted = try XCTUnwrap(messages.first { message in
            !appState.skippedMessages.contains { $0.message.id == message.id }
        })
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.skippedMessages.count, appState.skippedMessageLogLimit)
        XCTAssertTrue(appState.hasSkippedMessage(evicted, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(provider.headerFetchCallCount, messages.count)
    }

    func testDismissedSkippedMessageIsDurablySuppressed() async throws {
        let skipped = message(id: 1, from: "no-reply@x.com")
        let (appState, _, persistence) = makeAppState(fetch: .success([skipped]))
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        let entry = try XCTUnwrap(appState.skippedMessages.first)

        appState.dismissSkippedMessage(entry)
        await appState.pollInboxOnce()

        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertFalse(appState.hasSkippedMessage(skipped, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.processedMessages.contains(skipped, account: "me@gmail.com", mailbox: .inbox))
    }
}
