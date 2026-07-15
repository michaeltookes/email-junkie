import EmailJunkieMail
import Security
import XCTest
@testable import EmailJunkie

/// Shared test doubles for `AppState` tests: in-memory persistence, fake and
/// suspendable mail providers, and a failable secret store.

final class AppStateMemoryPersistence: PersistenceProvider {
    private var settings: Settings
    private(set) var voiceProfile: VoiceProfile?
    private(set) var processedMessages: ProcessedMessages
    private(set) var pendingDrafts: [Draft]
    private(set) var approvedDraftIdentities: Set<String>
    private(set) var processedSaveCount = 0
    private(set) var pendingDraftSaveCount = 0
    private(set) var approvedDraftSaveCount = 0
    private(set) var saveEvents: [String] = []
    var syncSaveError: Error?
    var pendingDraftSaveError: Error?
    var approvedDraftSaveError: Error?

    init(
        settings: Settings = .default,
        voiceProfile: VoiceProfile? = nil,
        processedMessages: ProcessedMessages = ProcessedMessages(),
        pendingDrafts: [Draft] = [],
        approvedDraftIdentities: Set<String> = []
    ) {
        self.settings = settings
        self.voiceProfile = voiceProfile
        self.processedMessages = processedMessages
        self.pendingDrafts = pendingDrafts
        self.approvedDraftIdentities = approvedDraftIdentities
    }

    func loadSettings() -> Settings { settings }
    func saveSettings(_ settings: Settings) { self.settings = settings }
    func saveSettingsSync(_ settings: Settings) throws {
        if let syncSaveError {
            throw syncSaveError
        }
        self.settings = settings
    }

    func loadVoiceProfile() -> VoiceProfile? { voiceProfile }
    func saveVoiceProfile(_ profile: VoiceProfile) { voiceProfile = profile }
    func removeVoiceProfile() { voiceProfile = nil }

    func loadProcessedMessages() -> ProcessedMessages { processedMessages }
    func saveProcessedMessages(_ processed: ProcessedMessages) {
        processedMessages = processed
        processedSaveCount += 1
        saveEvents.append("processed")
    }

    func loadPendingDrafts() -> [Draft] { pendingDrafts }
    func savePendingDraftsSync(_ drafts: [Draft]) throws {
        if let pendingDraftSaveError {
            throw pendingDraftSaveError
        }
        pendingDrafts = drafts
        pendingDraftSaveCount += 1
        saveEvents.append("pending")
    }

    func loadApprovedDraftIdentities() -> Set<String> { approvedDraftIdentities }
    func saveApprovedDraftIdentitiesSync(_ identities: Set<String>) throws {
        if let approvedDraftSaveError {
            throw approvedDraftSaveError
        }
        approvedDraftIdentities = identities
        approvedDraftSaveCount += 1
        saveEvents.append("approved")
    }
}

enum AppStatePersistenceError: LocalizedError {
    case writeDenied

    var errorDescription: String? {
        switch self {
        case .writeDenied:
            return "settings write denied"
        }
    }
}

final class FakeAppMailProvider: MailProvider, @unchecked Sendable {
    private let result: Result<Void, MailError>
    private let fetchResult: Result<[MailMessage], MailError>
    private let bodyResult: Result<Data, MailError>
    private let appendResult: Result<Void, MailError>
    private let sendResult: Result<Void, MailError>
    private(set) var lastCredentials: MailAccountCredentials?
    private(set) var fetchCallCount = 0
    private(set) var bodyFetchCallCount = 0
    private(set) var lastBodyUID: UInt32?
    private(set) var lastExpectedUIDValidity: UInt32?
    private(set) var appendedMailbox: Mailbox?
    private(set) var appendedRFC822: Data?
    private(set) var appendedFlags: [MailFlag]?
    private(set) var sentRFC822: Data?
    private(set) var sentEnvelope: SMTPEnvelope?

    init(
        result: Result<Void, MailError>,
        fetchResult: Result<[MailMessage], MailError> = .success([]),
        bodyResult: Result<Data, MailError> = .success(Data()),
        appendResult: Result<Void, MailError> = .success(()),
        sendResult: Result<Void, MailError> = .success(())
    ) {
        self.result = result
        self.fetchResult = fetchResult
        self.bodyResult = bodyResult
        self.appendResult = appendResult
        self.sendResult = sendResult
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        lastCredentials = credentials
        try result.get()
    }

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        fetchCallCount += 1
        return try fetchResult.get()
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        bodyFetchCallCount += 1
        lastBodyUID = uid
        lastExpectedUIDValidity = expectedUIDValidity
        return try bodyResult.get()
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {
        appendedMailbox = mailbox
        appendedRFC822 = rfc822
        appendedFlags = flags
        try appendResult.get()
    }

    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws {
        sentRFC822 = rfc822
        sentEnvelope = envelope
        try sendResult.get()
    }
}

final class SuspendedAppMailProvider: MailProvider, @unchecked Sendable {
    let didStartVerification = XCTestExpectation(description: "mail verification started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var lastCredentials: MailAccountCredentials?

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            lastCredentials = credentials
            self.continuation = continuation
            lock.unlock()
            didStartVerification.fulfill()
        }
    }

    func complete(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        []
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        Data()
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}
}

final class SuspendedSendMailProvider: MailProvider, @unchecked Sendable {
    let didStartSend = XCTestExpectation(description: "mail send started")
    private let lock = NSLock()
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private var sendCount = 0
    private var capturedEnvelope: SMTPEnvelope?

    var sentMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sendCount
    }

    var sentEnvelope: SMTPEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return capturedEnvelope
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        []
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        Data()
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}

    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            sendCount += 1
            capturedEnvelope = envelope
            sendContinuation = continuation
            lock.unlock()
            didStartSend.fulfill()
        }
    }

    func completeSend(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = sendContinuation
        sendContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

final class SuspendedBodyMailProvider: MailProvider, @unchecked Sendable {
    let didStartBodyFetch = XCTestExpectation(description: "body fetch started")
    private let lock = NSLock()
    private var bodyContinuation: CheckedContinuation<Data, Error>?
    private(set) var lastCredentials: MailAccountCredentials?

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        []
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        lock.lock()
        lastCredentials = credentials
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            bodyContinuation = continuation
            lock.unlock()
            didStartBodyFetch.fulfill()
        }
    }

    func completeBody(with result: Result<Data, Error>) {
        lock.lock()
        let continuation = bodyContinuation
        bodyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}
}

final class FakeLLMProvider: LLMProviding, @unchecked Sendable {
    private let result: Result<Void, LLMError>
    private let completion: Result<LLMResponse, LLMError>
    private(set) var lastProvider: LLMProviderKind?
    private(set) var lastAPIKey: String?
    private(set) var lastModel: String?
    private(set) var lastRequest: LLMRequest?

    init(
        result: Result<Void, LLMError>,
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: ""))
    ) {
        self.result = result
        self.completion = completion
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String) async throws {
        lastProvider = provider
        lastAPIKey = apiKey
        lastModel = model
        try result.get()
    }

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String
    ) async throws -> LLMResponse {
        lastProvider = provider
        lastAPIKey = apiKey
        lastRequest = request
        return try completion.get()
    }
}

final class SuspendedLLMProvider: LLMProviding, @unchecked Sendable {
    let didStartCompletion = XCTestExpectation(description: "LLM completion started")
    private let lock = NSLock()
    private var completionContinuation: CheckedContinuation<LLMResponse, Error>?
    private(set) var lastProvider: LLMProviderKind?
    private(set) var lastAPIKey: String?
    private(set) var lastRequest: LLMRequest?

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String
    ) async throws -> LLMResponse {
        lock.lock()
        lastProvider = provider
        lastAPIKey = apiKey
        lastRequest = request
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            completionContinuation = continuation
            lock.unlock()
            didStartCompletion.fulfill()
        }
    }

    func completeDraft(with result: Result<LLMResponse, Error>) {
        lock.lock()
        let continuation = completionContinuation
        completionContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

final class SuspendedLLMConnectionTester: LLMProviding, @unchecked Sendable {
    let didStartConnectionTest = XCTestExpectation(description: "LLM connection test started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var lastProvider: LLMProviderKind?
    private(set) var lastAPIKey: String?
    private(set) var lastModel: String?

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String) async throws {
        record(provider: provider, apiKey: apiKey, model: model)
        try await withCheckedThrowingContinuation { continuation in
            store(continuation)
            didStartConnectionTest.fulfill()
        }
    }

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String
    ) async throws -> LLMResponse {
        LLMResponse(text: "")
    }

    func complete(with result: Result<Void, Error>) {
        takeContinuation()?.resume(with: result)
    }

    private func record(provider: LLMProviderKind, apiKey: String, model: String) {
        lock.lock()
        lastProvider = provider
        lastAPIKey = apiKey
        lastModel = model
        lock.unlock()
    }

    private func store(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        let pendingContinuation = continuation
        self.continuation = nil
        lock.unlock()
        return pendingContinuation
    }
}

final class AppStateFailingSecretStore: SecretStore {
    var failOnSet: SecretKey?
    var failOnRemove: SecretKey?
    private var storage: [String: String]

    init(seed: [SecretKey: String] = [:]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        if failOnSet == key {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        if failOnRemove == key {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}
