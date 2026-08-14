import SentwiseMail
import XCTest
@testable import EmailJunkie

@MainActor
final class AppStateStaleThreadScanLimitTests: XCTestCase {

    private func draft(id: UInt32 = 5, subject: String = "Re:") -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 1,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: subject,
            sourceFrom: MailAddress(name: "Alice", email: "alice@x.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@x.com>",
            replySubject: "Re:",
            body: "Sounds good!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func message(id: UInt32, subject: String, from: String = "nobody@x.com") -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 1,
            from: MailAddress(email: from),
            subject: subject,
            date: "",
            messageID: "<\(id)@x.com>"
        )
    }

    private func result(ids: ClosedRange<UInt32>, offset: Int, hasMore: Bool = true) -> MailSearchResult {
        MailSearchResult(
            messages: ids.reversed().map { message(id: $0, subject: "Other \($0)") },
            totalMatches: 300,
            offset: offset,
            hasMore: hasMore
        )
    }

    private func makeAppState(provider: MailProvider) -> AppState {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        ))
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "Fresh reply.")))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        return appState
    }

    func testBlankSubjectSourceInspectionStopsAtPageLimit() async {
        let provider = SearchStubMailProvider()
        provider.pageResults[.inbox] = [
            0: result(ids: 451...500, offset: 0),
            50: result(ids: 401...450, offset: 50),
            100: result(ids: 351...400, offset: 100),
            150: result(ids: 301...350, offset: 150),
            200: result(ids: 251...300, offset: 200)
        ]
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(
            for: draft(),
            credentials: appState.mailCredentials
        )

        XCTAssertEqual(verdict, .fresh)
        let inboxRequests = provider.pageRequests.filter { $0.mailbox == .inbox }
        XCTAssertEqual(inboxRequests.map(\.offset), [0, 50, 100, 150])
    }

    func testBlankSubjectSourceInspectionStopsAtSourceUIDBoundary() async {
        let provider = SearchStubMailProvider()
        provider.pageResults[.inbox] = [
            0: MailSearchResult(messages: [message(id: 9, subject: "Other")], totalMatches: 100, offset: 0, hasMore: true),
            50: MailSearchResult(messages: [message(id: 4, subject: "Other")], totalMatches: 100, offset: 50, hasMore: true)
        ]
        let appState = makeAppState(provider: provider)

        let verdict = await appState.threadStalenessVerdict(
            for: draft(),
            credentials: appState.mailCredentials
        )

        XCTAssertEqual(verdict, .stale(.sourceMissing))
        let inboxRequests = provider.pageRequests.filter { $0.mailbox == .inbox }
        XCTAssertEqual(inboxRequests.map(\.offset), [0, 50])
    }
}
