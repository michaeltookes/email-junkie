import SentwiseMail
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

private actor GateableTranscriptLLMProvider: LLMProviding {
    private var succeeds = false
    private var completeCallCount = 0

    func setSucceeds(_ succeeds: Bool) {
        self.succeeds = succeeds
    }

    func callCount() -> Int {
        completeCallCount
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        completeCallCount += 1
        guard succeeds else {
            throw LLMError.http(status: 401, message: "bad key")
        }
        return LLMResponse(text: "Follow up.")
    }
}

@MainActor
final class AppStateWatchedTranscriptRetryTests: XCTestCase {

    func testWatchedTranscriptRetriesAfterLLMAuthenticationFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-auth-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let llm = GateableTranscriptLLMProvider()
        let persistence = AppStateMemoryPersistence(settings: watchedFolderSettings(dir: dir))
        let appState = makeAppState(persistence: persistence, secrets: connectedSecrets(), llm: llm)
        appState.startTranscriptFolderWatchingIfEnabled()
        guard let source = appState.transcriptFolderSource else {
            return XCTFail("Expected transcript folder source")
        }
        defer { appState.stopTranscriptFolderWatching() }
        source.fileStabilityDelayNanoseconds = 0

        try "Marcus: recap.".write(to: dir.appendingPathComponent("call.txt"), atomically: true, encoding: .utf8)
        await source.scanForNewTranscripts()
        await source.scanForNewTranscripts()
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.transcriptFolderError)
        var callCount = await llm.callCount()
        XCTAssertEqual(callCount, 1)

        await source.scanForNewTranscripts()
        callCount = await llm.callCount()
        XCTAssertEqual(callCount, 1)

        await llm.setSucceeds(true)
        appState.startTranscriptFolderWatchingIfEnabled()
        for _ in 0..<100 where appState.pendingDrafts.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        callCount = await llm.callCount()
        XCTAssertEqual(callCount, 2)
        XCTAssertNil(appState.transcriptFolderError)
    }

    func testWatchedTranscriptRejectedForAuthenticationRetriesAfterRestart() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-auth-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let persistence = AppStateMemoryPersistence(settings: watchedFolderSettings(dir: dir))
        let secrets = connectedSecrets()
        let firstAppState = makeAppState(
            persistence: persistence,
            secrets: secrets,
            llm: WatchedTranscriptRetryLLMProvider(completions: [
                .failure(.http(status: 401, message: "bad key")),
                .failure(.http(status: 401, message: "bad key")),
                .failure(.http(status: 401, message: "bad key")),
                .failure(.http(status: 401, message: "bad key"))
            ])
        )
        firstAppState.startTranscriptFolderWatchingIfEnabled()
        guard let firstSource = firstAppState.transcriptFolderSource else {
            return XCTFail("Expected first transcript folder source")
        }
        defer { firstAppState.stopTranscriptFolderWatching() }
        firstSource.fileStabilityDelayNanoseconds = 0

        try "Marcus: recap.".write(to: dir.appendingPathComponent("call.txt"), atomically: true, encoding: .utf8)
        await firstSource.scanForNewTranscripts()
        await firstSource.scanForNewTranscripts()
        await firstSource.scanForNewTranscripts()
        firstAppState.stopTranscriptFolderWatching()

        XCTAssertTrue(firstAppState.pendingDrafts.isEmpty)
        XCTAssertNotNil(firstAppState.transcriptFolderError)
        XCTAssertTrue(persistence.loadSettings().transcriptWatchedFolderSeenSnapshots?.isEmpty == true)

        let restartedAppState = makeAppState(
            persistence: persistence,
            secrets: secrets,
            llm: WatchedTranscriptRetryLLMProvider(completions: [
                .success(LLMResponse(text: "Follow up."))
            ])
        )
        restartedAppState.startTranscriptFolderWatchingIfEnabled()
        guard let restartedSource = restartedAppState.transcriptFolderSource else {
            return XCTFail("Expected restarted transcript folder source")
        }
        defer { restartedAppState.stopTranscriptFolderWatching() }
        restartedSource.fileStabilityDelayNanoseconds = 0

        await restartedSource.scanForNewTranscripts()
        await restartedSource.scanForNewTranscripts()

        XCTAssertEqual(restartedAppState.pendingDrafts.count, 1)
        XCTAssertNil(restartedAppState.transcriptFolderError)
    }

    func testWatchedFolderSeenSnapshotPersistenceFailureReturnsFalseAndRollsBack() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seen-persistence-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("call.txt")
        try "Marcus: recap.".write(to: transcript, atomically: true, encoding: .utf8)
        let snapshot = try XCTUnwrap(WatchedFolderFileSnapshot(url: transcript))
        let snapshots = [WatchedFolderScanner.seenKey(for: transcript): snapshot]
        let persistence = AppStateMemoryPersistence(settings: watchedFolderSettings(dir: dir))
        let appState = makeAppState(
            persistence: persistence,
            secrets: connectedSecrets(),
            llm: WatchedTranscriptRetryLLMProvider(completions: [])
        )
        persistence.syncSaveError = AppStatePersistenceError.writeDenied

        let didPersist = appState.persistTranscriptWatchedFolderSeenSnapshots(snapshots)

        XCTAssertFalse(didPersist)
        XCTAssertNil(appState.transcriptWatchedFolderSeenSnapshots)
        XCTAssertNil(persistence.loadSettings().transcriptWatchedFolderSeenSnapshots)
        XCTAssertEqual(appState.connectionError, "Couldn't save mailbox settings. settings write denied")
    }

    func testInactiveWatchedFolderSourceCannotPersistSnapshotsAfterFolderChange() throws {
        let firstDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inactive-seen-source-a-\(UUID().uuidString)", isDirectory: true)
        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inactive-seen-source-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }
        let persistence = AppStateMemoryPersistence(settings: watchedFolderSettings(dir: firstDir))
        let appState = makeAppState(
            persistence: persistence,
            secrets: connectedSecrets(),
            llm: WatchedTranscriptRetryLLMProvider(completions: [])
        )
        appState.startTranscriptFolderWatchingIfEnabled()
        guard let staleSource = appState.transcriptFolderSource else {
            return XCTFail("Expected transcript folder source")
        }
        defer { appState.stopTranscriptFolderWatching() }

        appState.setTranscriptWatchedFolderPath(secondDir.path)
        let staleTranscript = firstDir.appendingPathComponent("old.txt")
        try "Marcus: old recap.".write(to: staleTranscript, atomically: true, encoding: .utf8)
        let snapshot = try XCTUnwrap(WatchedFolderFileSnapshot(url: staleTranscript))
        let didPersist = staleSource.onSeenVersionsChanged?([
            WatchedFolderScanner.seenKey(for: staleTranscript): snapshot
        ])

        XCTAssertEqual(didPersist, false)
        XCTAssertNil(appState.transcriptWatchedFolderSeenSnapshots)
    }

    func testWatchedTranscriptCommitValidationPreventsPendingDraft() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-stale-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let persistence = AppStateMemoryPersistence(settings: watchedFolderSettings(dir: dir))
        let appState = makeAppState(
            persistence: persistence,
            secrets: connectedSecrets(),
            llm: WatchedTranscriptRetryLLMProvider(completions: [
                .success(LLMResponse(text: "Follow up."))
            ])
        )
        let ingested = try TranscriptIngest.fromPaste("Marcus: recap.")
        var validationCount = 0

        let result = await appState.handleWatchedTranscriptDelivery(
            ingested,
            shouldCommit: {
                validationCount += 1
                return validationCount == 1
            }
        )

        XCTAssertEqual(result, .retry)
        XCTAssertEqual(validationCount, 2)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
    }

    private func watchedFolderSettings(dir: URL) -> Settings {
        Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            transcriptWatchedFolderEnabled: true,
            transcriptWatchedFolderPath: dir.path
        )
    }

    private func connectedSecrets() -> InMemorySecretStore {
        InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
    }

    private func makeAppState(
        persistence: AppStateMemoryPersistence,
        secrets: InMemorySecretStore,
        llm: LLMProviding
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier()
        )
    }
}
