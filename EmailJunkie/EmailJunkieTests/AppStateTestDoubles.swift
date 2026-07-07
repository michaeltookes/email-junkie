import EmailJunkieMail
import Security
import XCTest
@testable import EmailJunkie

/// Shared test doubles for `AppState` tests: in-memory persistence, fake and
/// suspendable mail providers, and a failable secret store.

final class AppStateMemoryPersistence: PersistenceProvider {
    private var settings: Settings
    var syncSaveError: Error?

    init(settings: Settings = .default) {
        self.settings = settings
    }

    func loadSettings() -> Settings { settings }
    func saveSettings(_ settings: Settings) { self.settings = settings }
    func saveSettingsSync(_ settings: Settings) throws {
        if let syncSaveError {
            throw syncSaveError
        }
        self.settings = settings
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
    private(set) var lastCredentials: MailAccountCredentials?
    private(set) var lastBodyUID: UInt32?
    private(set) var lastExpectedUIDValidity: UInt32?

    init(
        result: Result<Void, MailError>,
        fetchResult: Result<[MailMessage], MailError> = .success([]),
        bodyResult: Result<Data, MailError> = .success(Data())
    ) {
        self.result = result
        self.fetchResult = fetchResult
        self.bodyResult = bodyResult
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
        try fetchResult.get()
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        lastBodyUID = uid
        lastExpectedUIDValidity = expectedUIDValidity
        return try bodyResult.get()
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
