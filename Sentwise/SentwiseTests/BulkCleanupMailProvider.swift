import SentwiseMail
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
    private(set) var lastAppliedSelection: MailBulkSelection?
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
        selection: MailBulkSelection?,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        applyCallCount += 1
        lastAppliedCredentials = credentials
        lastAppliedMailbox = mailbox
        lastAppliedCriteria = criteria
        lastAppliedAction = action
        lastAppliedSelection = selection
        let result = try applyResult.get()
        // Mirror the real provider: report progress as batches land.
        onProgress?(MailBulkProgress(processed: result.affectedCount, total: result.affectedCount))
        return result
    }
}

/// Models a provider whose filtered matches shrink pass over pass, the way a
/// visibility-capped mailbox (att.net/Yahoo) reveals older mail only after the
/// visible ones are removed (item 49). Each preview returns the next scripted
/// count; each apply "moves" exactly the selection it is given.
final class SweepBulkCleanupMailProvider: MailProvider, @unchecked Sendable {
    private var remainingCounts: [Int]
    private let applyError: MailError?

    private(set) var previewCallCount = 0
    private(set) var applyCallCount = 0
    private(set) var appliedSelectionCounts: [Int] = []

    /// - Parameter passCounts: match counts returned by successive previews. A
    ///   trailing `0` is appended automatically so the sweep terminates.
    init(passCounts: [Int], applyError: MailError? = nil) {
        remainingCounts = passCounts + [0]
        self.applyError = applyError
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
        let count = remainingCounts.first ?? 0
        guard count > 0 else { return .empty }
        let uids = (0..<count).map { UInt32(1_000 + $0) }
        return MailBulkPreview(
            matchCount: count,
            sample: [],
            isPartial: false,
            selection: MailBulkSelection(uidValidity: 1, uids: uids)
        )
    }

    // swiftlint:disable:next function_parameter_count
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selection: MailBulkSelection?,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        applyCallCount += 1
        if let applyError { throw applyError }
        let moved = selection?.uids.count ?? 0
        appliedSelectionCounts.append(moved)
        // That pass removed the visible matches; the next preview reveals the
        // previously-hidden remainder.
        if !remainingCounts.isEmpty { remainingCounts.removeFirst() }
        return MailBulkResult(action: action, affectedCount: moved)
    }
}

/// A provider whose approved preview has matches, but whose next preview is
/// empty because the mailbox changed before the sweep started.
final class VanishingSweepProvider: MailProvider, @unchecked Sendable {
    private var previewCounts: [Int]
    private(set) var applyCallCount = 0

    init(initialCount: Int) {
        previewCounts = [initialCount, 0]
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
        let count = previewCounts.isEmpty ? 0 : previewCounts.removeFirst()
        guard count > 0 else { return .empty }
        return MailBulkPreview(
            matchCount: count,
            sample: [],
            isPartial: false,
            selection: MailBulkSelection(uidValidity: 1, uids: (0..<count).map { UInt32(1_000 + $0) })
        )
    }

    // swiftlint:disable:next function_parameter_count
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selection: MailBulkSelection?,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        applyCallCount += 1
        return MailBulkResult(action: action, affectedCount: selection?.uids.count ?? 0)
    }
}

final class SuspendedBulkCleanupMailProvider: MailProvider, @unchecked Sendable {
    let didStartPreview = XCTestExpectation(description: "bulk cleanup preview started")
    let didStartApply = XCTestExpectation(description: "bulk cleanup apply started")
    private let immediatePreview: MailBulkPreview?
    private let applyResult: MailBulkResult
    private let lock = NSLock()
    private var previewContinuation: CheckedContinuation<MailBulkPreview, Error>?
    private var applyContinuation: CheckedContinuation<MailBulkResult, Error>?
    private var applyProgress: (@Sendable (MailBulkProgress) -> Void)?
    private(set) var previewCallCount = 0
    private(set) var applyCallCount = 0

    init(
        previewResult: MailBulkPreview? = nil,
        applyResult: MailBulkResult = MailBulkResult(action: .markRead, affectedCount: 0)
    ) {
        immediatePreview = previewResult
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
        if let immediatePreview {
            return immediatePreview
        }
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

    func reportApplyProgress(_ progress: MailBulkProgress) {
        lock.lock()
        let applyProgress = applyProgress
        lock.unlock()
        applyProgress?(progress)
    }

    func completeApply(with result: Result<MailBulkResult, Error>? = nil) {
        lock.lock()
        let continuation = applyContinuation
        applyContinuation = nil
        applyProgress = nil
        lock.unlock()
        continuation?.resume(with: result ?? .success(applyResult))
    }

    // swiftlint:disable:next function_parameter_count
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selection: MailBulkSelection?,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        applyCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            applyContinuation = continuation
            applyProgress = onProgress
            lock.unlock()
            didStartApply.fulfill()
        }
    }
}
