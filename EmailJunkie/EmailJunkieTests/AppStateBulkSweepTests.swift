import EmailJunkieMail
import XCTest
@testable import EmailJunkie

/// Tests for the verify-until-stable bulk sweep (item 49).
///
/// att.net/Yahoo only exposes ~10,000 messages over IMAP at once, so a single
/// pass can never clear a larger filtered set — removing the visible matches
/// reveals older ones. The sweep loops preview+apply until the filter reports
/// zero, which is the only way "clean all" actually clears all on such a mailbox.
@MainActor
final class AppStateBulkSweepTests: XCTestCase {

    private func makeAppState(provider: MailProvider, connected: Bool = true) -> AppState {
        let secrets = connected
            ? InMemorySecretStore(seed: [.mailAppPassword: "app-pw"])
            : InMemorySecretStore()
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: connected ? "me@gmail.com" : ""
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        // No real delays in tests.
        appState.bulkSweepPacingNanoseconds = 0
        return appState
    }

    // MARK: - Convergence

    func testSweepLoopsUntilTheFilterReportsZero() async {
        // The exact att.net convergence we saw live: 605 visible, then 318, then
        // 134 as older mail slid into view.
        let provider = SweepBulkCleanupMailProvider(passCounts: [605, 318, 134])
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        XCTAssertEqual(provider.appliedSelectionCounts, [605, 318, 134])
        XCTAssertEqual(appState.bulk.completionMessage, "Moved 1057 messages to Trash.")
        XCTAssertNil(appState.bulk.error)
        XCTAssertFalse(appState.bulk.isSweeping)
    }

    func testSweepPreviewsOnceMoreThanItAppliesToConfirmZero() async {
        let provider = SweepBulkCleanupMailProvider(passCounts: [200, 50])
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .archive

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        // One approved preview, then two sweep applies and a final zero preview.
        XCTAssertEqual(provider.applyCallCount, 2)
        XCTAssertEqual(provider.previewCallCount, 4)
        XCTAssertEqual(appState.bulk.completionMessage, "Archived 250 messages.")
    }

    func testSweepOnAFilterThatEmptiedAfterPreviewMovesNothing() async {
        let provider = VanishingSweepProvider(initialCount: 25)
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        XCTAssertEqual(provider.applyCallCount, 0)
        XCTAssertEqual(appState.bulk.completionMessage, "Moved 0 messages to Trash.")
    }

    // MARK: - Termination safety

    /// If a pass reports moving nothing (e.g. every UID vanished) the loop must
    /// stop rather than spin forever, even though the preview still shows matches.
    func testSweepStopsWhenAPassMakesNoProgress() async {
        let provider = StuckSweepProvider(matchCount: 500)
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        XCTAssertLessThanOrEqual(provider.applyCallCount, 2, "must not loop forever on zero progress")
        XCTAssertFalse(appState.bulk.isSweeping)
    }

    func testChangingTheFilterAfterPreviewBlocksSweep() async {
        let provider = SweepBulkCleanupMailProvider(passCounts: [9])
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.previewBulkCleanup()
        appState.browser.sender = "boss@work.com"
        await appState.applyBulkCleanupSweep()

        XCTAssertEqual(provider.applyCallCount, 0, "must not sweep a filter the user never previewed")
        XCTAssertNil(appState.bulk.preview)
        XCTAssertEqual(
            appState.bulk.error,
            "The search changed since the preview. Preview again before running cleanup."
        )
    }

    func testSweepReportsIncompleteWhenPassLimitIsReached() async {
        let provider = SweepBulkCleanupMailProvider(
            passCounts: Array(repeating: 1, count: AppState.bulkSweepMaxPasses)
        )
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        XCTAssertEqual(provider.applyCallCount, AppState.bulkSweepMaxPasses)
        XCTAssertNil(appState.bulk.completionMessage)
        let error = appState.bulk.error ?? ""
        XCTAssertTrue(error.contains("Moved \(AppState.bulkSweepMaxPasses) messages"), error)
        XCTAssertTrue(error.contains("before verifying the filter was empty"), error)
    }

    // MARK: - Action routing

    /// Marking read removes nothing, so looping cannot reach past the visibility
    /// cap; the sweep entry point must fall back to a single pass instead of
    /// looping pointlessly.
    func testMarkReadDoesNotSweep() async {
        let provider = SweepBulkCleanupMailProvider(passCounts: [300, 300, 300])
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .markRead

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        XCTAssertLessThanOrEqual(provider.applyCallCount, 1, "mark read must be a single pass, not a sweep")
    }

    // MARK: - Rate-limit resilience

    /// A transient "try again later" must not kill the whole sweep — it should
    /// back off and retry, then finish. This is the att.net failure we hit live.
    func testSweepRidesOutTransientRateLimitAndCompletes() async {
        let provider = FlakySweepProvider(
            passCounts: [500, 200],
            transientFailuresBeforeSuccess: 3,
            transientError: .commandFailed("SEARCH Server error - Please try again later")
        )
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        XCTAssertEqual(appState.bulk.completionMessage, "Moved 700 messages to Trash.")
        XCTAssertNil(appState.bulk.error, "a recovered transient failure must not surface as an error")
    }

    /// Past the retry ceiling, give up — but report what was already moved and
    /// invite another run, rather than reading as a total failure.
    func testPersistentRateLimitReportsPartialProgress() async {
        // First pass moves 500, then every later attempt is throttled forever.
        let provider = FlakySweepProvider(
            passCounts: [500, 200],
            successesBeforeTransient: 1,
            transientFailuresBeforeSuccess: 999,
            transientError: .commandFailed("SEARCH Server error - Please try again later")
        )
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        XCTAssertNil(appState.bulk.completionMessage)
        let error = appState.bulk.error ?? ""
        XCTAssertTrue(error.contains("Moved 500"), error)
        XCTAssertTrue(error.contains("run it again"), error)
    }

    func testTransientErrorClassification() {
        XCTAssertTrue(AppState.isTransientBulkError(
            MailError.commandFailed("SEARCH Server error - Please try again later")
        ))
        XCTAssertTrue(AppState.isTransientBulkError(MailError.commandFailed("Too many requests")))
        XCTAssertFalse(AppState.isTransientBulkError(MailError.commandFailed("Unknown command")))
        XCTAssertFalse(AppState.isTransientBulkError(MailError.authenticationFailed("bad")))
    }

    // MARK: - Failure handling

    func testSweepSurfacesAnApplyFailureWithoutClaimingSuccess() async {
        let provider = SweepBulkCleanupMailProvider(passCounts: [500], applyError: .commandFailed("MOVE failed"))
        let appState = makeAppState(provider: provider)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanupSweep()

        XCTAssertNil(appState.bulk.completionMessage)
        XCTAssertEqual(appState.bulk.error, AppState.message(for: MailError.commandFailed("MOVE failed")))
        XCTAssertFalse(appState.bulk.isSweeping)
    }

    func testSweepWithoutAccountIsRefused() async {
        let provider = SweepBulkCleanupMailProvider(passCounts: [500])
        let appState = makeAppState(provider: provider, connected: false)
        appState.browser.sender = "spam@junk.com"
        appState.bulk.action = .moveToTrash

        await appState.applyBulkCleanupSweep()

        XCTAssertEqual(provider.applyCallCount, 0)
        XCTAssertEqual(appState.bulk.error, "Connect an account first.")
    }

    // MARK: - Copy

    /// The move confirmation must warn that a sweep can exceed the visible count,
    /// so approving is informed consent, not a surprise.
    func testMoveConfirmationWarnsAboutRepeatedPasses() {
        let message = AppState.bulkConfirmationMessage(for: .moveToTrash, matchCount: 605, isPartial: false)
        XCTAssertTrue(message.contains("repeated passes"), message)
        XCTAssertTrue(message.contains("605"), message)
        XCTAssertTrue(message.contains("recover them from Trash"), message)
    }
}

/// Like `SweepBulkCleanupMailProvider`, but throws a transient error on the
/// first N apply attempts before letting the pass succeed — models a provider
/// rate-limiting a too-fast sweep (item 49).
private final class FlakySweepProvider: MailProvider, @unchecked Sendable {
    private var remainingCounts: [Int]
    private var successesRemaining: Int
    private var transientBudget: Int
    private let transientError: MailError

    init(
        passCounts: [Int],
        successesBeforeTransient: Int = 0,
        transientFailuresBeforeSuccess: Int,
        transientError: MailError
    ) {
        remainingCounts = passCounts + [0]
        successesRemaining = successesBeforeTransient
        transientBudget = transientFailuresBeforeSuccess
        self.transientError = transientError
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
        let count = remainingCounts.first ?? 0
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
        if successesRemaining <= 0, transientBudget > 0 {
            transientBudget -= 1
            throw transientError
        }
        if successesRemaining > 0 { successesRemaining -= 1 }
        let moved = selection?.uids.count ?? 0
        if !remainingCounts.isEmpty { remainingCounts.removeFirst() }
        return MailBulkResult(action: action, affectedCount: moved)
    }
}

/// A provider whose approved preview has matches, but whose next preview is
/// empty because the mailbox changed before the sweep started.
private final class VanishingSweepProvider: MailProvider, @unchecked Sendable {
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

/// A provider whose filter never empties but whose applies move nothing — the
/// pathological "no progress" case the sweep must not loop on forever.
private final class StuckSweepProvider: MailProvider, @unchecked Sendable {
    private let matchCount: Int
    private(set) var applyCallCount = 0

    init(matchCount: Int) { self.matchCount = matchCount }

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
        MailBulkPreview(
            matchCount: matchCount,
            sample: [],
            isPartial: false,
            selection: MailBulkSelection(uidValidity: 1, uids: (0..<matchCount).map { UInt32(1_000 + $0) })
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
        return MailBulkResult(action: action, affectedCount: 0)
    }
}
