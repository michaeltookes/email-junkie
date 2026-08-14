import SentwiseMail
import XCTest
@testable import EmailJunkie

/// Tests for per-row checkbox selection driving bulk cleanup (item 47).
///
/// The point of the feature is granularity: "just these three" must be
/// distinguishable from "all 605 matching the filter", and acting on a checked
/// set must send exactly those UIDs and nothing else.
@MainActor
final class AppStateBulkSelectionTests: XCTestCase {

    private func messages(_ count: Int, uidValidity: UInt32? = 7) -> [MailMessage] {
        (0..<count).map { index in
            MailMessage(
                id: UInt32(100 + index),
                uidValidity: uidValidity,
                from: MailAddress(name: "Sender", email: "spam\(index)@junk.com"),
                subject: "Offer \(index)",
                date: "",
                messageID: "<\(index)@junk.com>"
            )
        }
    }

    private func makeAppState(provider: MailProvider, connected: Bool = true) -> AppState {
        let secrets = connected
            ? InMemorySecretStore(seed: [.mailAppPassword: "app-pw"])
            : InMemorySecretStore()
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: connected ? "me@gmail.com" : ""
        ))
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    /// Puts the browser in a realistic post-search state with `count` loaded rows.
    private func seedResults(
        _ appState: AppState,
        count: Int,
        totalMatches: Int? = nil,
        mailbox: Mailbox = .inbox
    ) {
        let loaded = messages(count)
        appState.browser.results = loaded
        appState.browser.totalMatches = totalMatches ?? count
        appState.browser.resultQuery = MailboxBrowserQuery(
            mailbox: mailbox,
            criteria: appState.browser.criteria
        )
    }

    // MARK: - Selection state

    func testTogglingChecksAndUnchecksARow() {
        let appState = makeAppState(provider: BulkCleanupMailProvider())
        seedResults(appState, count: 3)

        appState.browser.toggleSelection(100)
        XCTAssertEqual(appState.browser.selectedMessages.map(\.id), [100])
        XCTAssertTrue(appState.browser.hasSelection)

        appState.browser.toggleSelection(100)
        XCTAssertFalse(appState.browser.hasSelection)
    }

    func testSelectedMessagesIgnoreIDsNotInTheLoadedRows() {
        let appState = makeAppState(provider: BulkCleanupMailProvider())
        seedResults(appState, count: 2)

        appState.browser.toggleSelection(100)
        appState.browser.toggleSelection(9_999)

        XCTAssertEqual(
            appState.browser.selectedMessages.map(\.id),
            [100],
            "a checked ID with no matching row must not count as selected"
        )
    }

    func testCheckAllListedSelectsOnlyLoadedRows() {
        let appState = makeAppState(provider: BulkCleanupMailProvider())
        seedResults(appState, count: 3, totalMatches: 605)

        appState.browser.selectAllLoaded()

        XCTAssertEqual(appState.browser.selectedMessages.count, 3)
        XCTAssertTrue(appState.browser.areAllLoadedSelected)
    }

    func testClearSelectionEmptiesIt() {
        let appState = makeAppState(provider: BulkCleanupMailProvider())
        seedResults(appState, count: 3)
        appState.browser.selectAllLoaded()

        appState.browser.clearSelection()

        XCTAssertFalse(appState.browser.hasSelection)
    }

    /// A checked UID refers to a row in the old result set; carrying it across a
    /// new search could act on a message the user can no longer see.
    func testNewSearchClearsSelection() async {
        let appState = makeAppState(provider: BulkCleanupMailProvider())
        seedResults(appState, count: 3)
        appState.browser.selectAllLoaded()

        await appState.runMailboxSearch()

        XCTAssertFalse(appState.browser.hasSelection)
    }

    // MARK: - Applying to a selection

    func testApplyingToSelectionSendsExactlyTheCheckedUIDs() async {
        let provider = BulkCleanupMailProvider(
            applyResult: .success(MailBulkResult(action: .moveToTrash, affectedCount: 2))
        )
        let appState = makeAppState(provider: provider)
        seedResults(appState, count: 5, totalMatches: 605)
        appState.bulk.action = .moveToTrash
        appState.browser.toggleSelection(101)
        appState.browser.toggleSelection(103)

        await appState.applyBulkCleanupToSelectedMessages()

        XCTAssertEqual(provider.applyCallCount, 1)
        XCTAssertEqual(
            provider.lastAppliedSelection?.uids,
            [101, 103],
            "must act on the checked rows only, not the whole match set"
        )
        XCTAssertEqual(provider.lastAppliedSelection?.uidValidity, 7)
        XCTAssertEqual(provider.lastAppliedAction, .moveToTrash)
    }

    func testApplyingToSelectionNeedsNoServerPreviewScan() async {
        let provider = BulkCleanupMailProvider(
            applyResult: .success(MailBulkResult(action: .markRead, affectedCount: 1))
        )
        let appState = makeAppState(provider: provider)
        seedResults(appState, count: 3)
        appState.browser.toggleSelection(100)

        await appState.applyBulkCleanupToSelectedMessages()

        XCTAssertEqual(
            provider.previewCallCount,
            0,
            "the checked rows are already visible — rescanning the mailbox is wasted work"
        )
        XCTAssertEqual(provider.applyCallCount, 1)
    }

    func testApplyingWithNothingCheckedIsRefused() async {
        let provider = BulkCleanupMailProvider()
        let appState = makeAppState(provider: provider)
        seedResults(appState, count: 3)

        await appState.applyBulkCleanupToSelectedMessages()

        XCTAssertEqual(provider.applyCallCount, 0)
        XCTAssertEqual(appState.bulk.error, "Check at least one message first.")
    }

    func testApplyingToSelectionWithoutAccountIsRefused() async {
        let provider = BulkCleanupMailProvider()
        let appState = makeAppState(provider: provider, connected: false)
        seedResults(appState, count: 3)
        appState.browser.toggleSelection(100)

        await appState.applyBulkCleanupToSelectedMessages()

        XCTAssertEqual(provider.applyCallCount, 0)
        XCTAssertEqual(appState.bulk.error, "Connect an account first.")
    }

    func testArchiveSelectionFromGmailAllMailIsRefused() async {
        let provider = BulkCleanupMailProvider(
            applyResult: .success(MailBulkResult(action: .archive, affectedCount: 1))
        )
        let appState = makeAppState(provider: provider)
        seedResults(appState, count: 2, mailbox: .allMail)
        appState.bulk.action = .archive
        appState.browser.toggleSelection(100)

        XCTAssertTrue(appState.bulkSelectionArchiveUnavailable)

        await appState.applyBulkCleanupToSelectedMessages()

        XCTAssertEqual(provider.applyCallCount, 0)
        XCTAssertEqual(appState.bulk.error, AppState.bulkArchiveUnavailableMessage)
    }

    /// The rows came from a specific folder. If the picker moved on, the checked
    /// UIDs may mean different messages there, so the run must not proceed.
    func testSwitchingFolderAfterCheckingBlocksTheRun() async {
        let provider = BulkCleanupMailProvider()
        let appState = makeAppState(provider: provider)
        seedResults(appState, count: 3)
        appState.browser.toggleSelection(100)
        appState.browser.mailbox = .sent

        await appState.applyBulkCleanupToSelectedMessages()

        XCTAssertEqual(provider.applyCallCount, 0, "must not clean a folder the rows did not come from")
    }

    func testSuccessfulSelectionRunReportsTheCount() async {
        let provider = BulkCleanupMailProvider(
            applyResult: .success(MailBulkResult(action: .archive, affectedCount: 2))
        )
        let appState = makeAppState(provider: provider)
        seedResults(appState, count: 4)
        appState.bulk.action = .archive
        appState.browser.toggleSelection(100)
        appState.browser.toggleSelection(101)

        await appState.applyBulkCleanupToSelectedMessages()

        XCTAssertEqual(appState.bulk.completionMessage, "Archived 2 messages.")
        XCTAssertNil(appState.bulk.error)
    }

    func testSelectionRunFailureSurfacesMessage() async {
        let provider = BulkCleanupMailProvider(
            applyResult: .failure(.commandFailed("MOVE not supported"))
        )
        let appState = makeAppState(provider: provider)
        seedResults(appState, count: 3)
        appState.bulk.action = .moveToTrash
        appState.browser.toggleSelection(100)

        await appState.applyBulkCleanupToSelectedMessages()

        XCTAssertNil(appState.bulk.completionMessage)
        XCTAssertEqual(
            appState.bulk.error,
            AppState.message(for: MailError.commandFailed("MOVE not supported"))
        )
    }

    // MARK: - Copy

    /// Selection scope must not borrow the filter wording, or a 3-message action
    /// would read as if it hit everything matching the search.
    func testSelectionConfirmationNamesCheckedCountNotTheFilter() {
        let message = AppState.bulkSelectionConfirmationMessage(for: .moveToTrash, count: 3)
        XCTAssertEqual(
            message,
            "Move 3 checked messages to Trash? You can recover them from Trash."
        )
        XCTAssertFalse(message.contains("matching this filter"), message)
    }

    func testSelectionConfirmationIsSingularForOneMessage() {
        XCTAssertEqual(
            AppState.bulkSelectionConfirmationMessage(for: .archive, count: 1),
            "Archive 1 checked message? You can find them in the Archive folder."
        )
    }
}
