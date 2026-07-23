import EmailJunkieMail
import Foundation
import XCTest

/// In-memory `MailProvider` for bulk-cleanup tests (item 42): records what was
/// previewed and applied so tests can assert the *exact* mailbox and criteria
/// each call used — no network.
final class BulkCleanupMailProvider: MailProvider, @unchecked Sendable {
    private let previewResult: Result<MailBulkPreview, MailError>
    private let applyResult: Result<MailBulkResult, MailError>

    private(set) var previewCallCount = 0
    private(set) var applyCallCount = 0
    private(set) var lastPreviewCredentials: MailAccountCredentials?
    private(set) var lastPreviewMailbox: Mailbox?
    private(set) var lastPreviewCriteria: MailSearchCriteria?
    private(set) var lastAppliedCredentials: MailAccountCredentials?
    private(set) var lastAppliedMailbox: Mailbox?
    private(set) var lastAppliedCriteria: MailSearchCriteria?
    private(set) var lastAppliedAction: MailBulkAction?
    private(set) var lastSelectionCap: Int?

    init(
        previewResult: Result<MailBulkPreview, MailError> = .success(.empty),
        applyResult: Result<MailBulkResult, MailError> = .success(
            MailBulkResult(action: .markRead, affectedCount: 0)
        )
    ) {
        self.previewResult = previewResult
        self.applyResult = applyResult
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data { Data() }

    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult { .empty(offset: offset) }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}

    func previewBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        sampleLimit: Int,
        selectionCap: Int
    ) async throws -> MailBulkPreview {
        previewCallCount += 1
        lastPreviewCredentials = credentials
        lastPreviewMailbox = mailbox
        lastPreviewCriteria = criteria
        lastSelectionCap = selectionCap
        return try previewResult.get()
    }

    // swiftlint:disable:next function_parameter_count
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        applyCallCount += 1
        lastAppliedCredentials = credentials
        lastAppliedMailbox = mailbox
        lastAppliedCriteria = criteria
        lastAppliedAction = action
        let result = try applyResult.get()
        // Mirror the real provider: report progress as batches land.
        onProgress?(MailBulkProgress(processed: result.affectedCount, total: result.affectedCount))
        return result
    }
}

final class SuspendedBulkCleanupMailProvider: MailProvider, @unchecked Sendable {
    let didStartPreview = XCTestExpectation(description: "bulk cleanup preview started")
    private let lock = NSLock()
    private var previewContinuation: CheckedContinuation<MailBulkPreview, Error>?
    private(set) var previewCallCount = 0
    private(set) var applyCallCount = 0

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data { Data() }

    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult { .empty(offset: offset) }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}

    func previewBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        sampleLimit: Int,
        selectionCap: Int
    ) async throws -> MailBulkPreview {
        previewCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            previewContinuation = continuation
            lock.unlock()
            didStartPreview.fulfill()
        }
    }

    func completePreview(with result: Result<MailBulkPreview, Error>) {
        lock.lock()
        let continuation = previewContinuation
        previewContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    // swiftlint:disable:next function_parameter_count
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        applyCallCount += 1
        return MailBulkResult(action: action, affectedCount: 0)
    }
}
