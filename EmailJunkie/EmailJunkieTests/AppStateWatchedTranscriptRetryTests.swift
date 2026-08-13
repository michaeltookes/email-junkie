import EmailJunkieMail
import XCTest
@testable import EmailJunkie

private actor WatchedTranscriptRetryLLMProvider: LLMProviding {
    private var completions: [Result<LLMResponse, LLMError>]

    init(completions: [Result<LLMResponse, LLMError>]) {
        self.completions = completions
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        let next = completions.isEmpty
            ? Result.success(LLMResponse(text: "Follow up."))
            : completions.removeFirst()
        return try next.get()
    }
}

@MainActor
final class AppStateWatchedTranscriptRetryTests: XCTestCase {

    func testWatchedTranscriptRetriesAfterLLMAuthenticationFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-auth-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let llm = WatchedTranscriptRetryLLMProvider(completions: [
            .failure(.http(status: 401, message: "bad key")),
            .success(LLMResponse(text: "Follow up."))
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            transcriptWatchedFolderEnabled: true,
            transcriptWatchedFolderPath: dir.path
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(seed: [
                .mailAppPassword: "app-pw",
                .llmAPIKey(provider: "anthropic"): "sk-live"
            ]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier()
        )
        appState.startTranscriptFolderWatchingIfEnabled()
        guard let source = appState.transcriptFolderSource else {
            return XCTFail("Expected transcript folder source")
        }
        source.fileStabilityDelayNanoseconds = 0

        try "Marcus: recap.".write(to: dir.appendingPathComponent("call.txt"), atomically: true, encoding: .utf8)
        await source.scanForNewTranscripts()
        await source.scanForNewTranscripts()
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.transcriptFolderError)

        await source.scanForNewTranscripts()

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertNil(appState.transcriptFolderError)
    }
}
