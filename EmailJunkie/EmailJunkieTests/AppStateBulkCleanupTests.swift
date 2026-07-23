import EmailJunkieMail
import XCTest
@testable import EmailJunkie

/// Tests for the bulk-cleanup actions on `AppState` (item 42), driven by an
/// in-memory provider — no network.
///
/// The emphasis is on the safety contract: nothing runs without a preview, a run
/// uses exactly the previewed filter, and a changed filter invalidates approval.
@MainActor
final class AppStateBulkCleanupTests: XCTestCase {

    private func sample(_ count: Int) -> [MailMessage] {
        (0..<count).map { index in
            MailMessage(
                id: UInt32(100 + index),
                uidValidity: 1,
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

    // MARK: - Preview

    func testPreviewReportsMatchesWithoutApplying() async {
        let provider = BulkCleanupMailProvider(
            previewResult: .success(MailBulkPreview(matchCount: 120, sample: sample(3), isPartial: false))
        )
        let appState = makeAppState(provider: provider)

        await appState.previewBulkCleanup()

        XCTAssertEqual(appState.bulk.preview?.matchCount, 120)
        XCTAssertEqual(appState.bulk.preview?.sample.count, 3)
        XCTAssertEqual(provider.applyCallCount, 0, "previewing must never change the mailbox")
        XCTAssertTrue(appState.bulk.canApply)
    }

    func testPreviewUsesTheCurrentFilter() async {
        let provider = BulkCleanupMailProvider(
            previewResult: .success(MailBulkPreview(matchCount: 5, sample: [], isPartial: false))
        )
        let appState = makeAppState(provider: provider)
        appState.browser.mailbox = .inbox
        appState.browser.sender = "spam@junk.com"
        appState.browser.readState = .unreadOnly

        await appState.previewBulkCleanup()

        XCTAssertEqual(provider.lastPreviewMailbox, .inbox)
        XCTAssertEqual(provider.lastPreviewCriteria?.from, "spam@junk.com")
        XCTAssertEqual(provider.lastPreviewCriteria?.readState, .unreadOnly)
    }

    func testPreviewIsBoundedBySelectionCap() async {
        let provider = BulkCleanupMailProvider(
            previewResult: .success(MailBulkPreview(matchCount: 5, sample: [], isPartial: false))
        )
        let appState = makeAppState(provider: provider)

        await appState.previewBulkCleanup()

        XCTAssertEqual(provider.lastSelectionCap, AppState.bulkSelectionCap)
    }

    func testPreviewWithoutAccountReportsClearError() async {
        let provider = BulkCleanupMailProvider()
        let appState = makeAppState(provider: provider, connected: false)

        await appState.previewBulkCleanup()

        XCTAssertEqual(appState.bulk.error, "Connect an account first.")
        XCTAssertEqual(provider.previewCallCount, 0)
    }

    func testPreviewFailureSurfacesMessage() async {
        let provider = BulkCleanupMailProvider(previewResult: .failure(.resultTooLarge))
        let appState = makeAppState(provider: provider)

        await appState.previewBulkCleanup()

        XCTAssertNil(appState.bulk.preview)
        XCTAssertFalse(appState.bulk.canApply)
        XCTAssertEqual(appState.bulk.error, AppState.message(for: MailError.resultTooLarge))
    }

    func testEmptyPreviewCannotBeApplied() async {
        let provider = BulkCleanupMailProvider(previewResult: .success(.empty))
        let appState = makeAppState(provider: provider)

        await appState.previewBulkCleanup()

        XCTAssertFalse(appState.bulk.canApply, "nothing matched, so there is nothing to confirm")
    }

    // MARK: - Apply

    func testApplyWithoutPreviewIsRefused() async {
        let provider = BulkCleanupMailProvider()
        let appState = makeAppState(provider: provider)

        await appState.applyBulkCleanup()

        XCTAssertEqual(provider.applyCallCount, 0)
        XCTAssertEqual(appState.bulk.error, "Preview the cleanup before running it.")
    }

    func testApplyUsesThePreviewedFilterNotLiveInputs() async {
        let provider = BulkCleanupMailProvider(
            previewResult: .success(MailBulkPreview(matchCount: 9, sample: [], isPartial: false)),
            applyResult: .success(MailBulkResult(action: .moveToTrash, affectedCount: 9))
        )
        let appState = makeAppState(provider: provider)
        appState.bulk.action = .moveToTrash
        appState.browser.sender = "spam@junk.com"

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanup()

        XCTAssertEqual(provider.applyCallCount, 1)
        XCTAssertEqual(provider.lastAppliedCriteria?.from, "spam@junk.com")
        XCTAssertEqual(provider.lastAppliedAction, .moveToTrash)
    }

    /// The core safety property: approving a preview approves *that* set of
    /// messages. Editing the filter afterward must invalidate the approval
    /// rather than silently deleting a different set.
    func testChangingTheFilterAfterPreviewBlocksTheRun() async {
        let provider = BulkCleanupMailProvider(
            previewResult: .success(MailBulkPreview(matchCount: 9, sample: [], isPartial: false)),
            applyResult: .success(MailBulkResult(action: .moveToTrash, affectedCount: 9))
        )
        let appState = makeAppState(provider: provider)
        appState.bulk.action = .moveToTrash
        appState.browser.sender = "spam@junk.com"

        await appState.previewBulkCleanup()
        appState.browser.sender = "boss@work.com"
        await appState.applyBulkCleanup()

        XCTAssertEqual(provider.applyCallCount, 0, "must not act on a filter the user never previewed")
        XCTAssertNil(appState.bulk.preview)
        XCTAssertEqual(
            appState.bulk.error,
            "The search changed since the preview. Preview again before running cleanup."
        )
    }

    func testChangingTheFolderAfterPreviewBlocksTheRun() async {
        let provider = BulkCleanupMailProvider(
            previewResult: .success(MailBulkPreview(matchCount: 9, sample: [], isPartial: false))
        )
        let appState = makeAppState(provider: provider)

        await appState.previewBulkCleanup()
        appState.browser.mailbox = .sent
        await appState.applyBulkCleanup()

        XCTAssertEqual(provider.applyCallCount, 0, "must not clean a folder the user never previewed")
    }

    func testSuccessfulApplyReportsCountAndClearsPreview() async {
        let provider = BulkCleanupMailProvider(
            previewResult: .success(MailBulkPreview(matchCount: 42, sample: [], isPartial: false)),
            applyResult: .success(MailBulkResult(action: .markRead, affectedCount: 42))
        )
        let appState = makeAppState(provider: provider)

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanup()

        XCTAssertEqual(appState.bulk.completionMessage, "Marked 42 messages as read.")
        XCTAssertNil(appState.bulk.preview, "a stale preview must not stay actionable after a run")
        XCTAssertFalse(appState.bulk.canApply)
        XCTAssertNil(appState.bulk.error)
    }

    func testApplyFailureSurfacesMessageAndDoesNotClaimSuccess() async {
        let provider = BulkCleanupMailProvider(
            previewResult: .success(MailBulkPreview(matchCount: 9, sample: [], isPartial: false)),
            applyResult: .failure(.commandFailed("MOVE not supported"))
        )
        let appState = makeAppState(provider: provider)

        await appState.previewBulkCleanup()
        await appState.applyBulkCleanup()

        XCTAssertNil(appState.bulk.completionMessage)
        XCTAssertEqual(
            appState.bulk.error,
            AppState.message(for: MailError.commandFailed("MOVE not supported"))
        )
    }

    // MARK: - Copy

    func testConfirmationNamesTheCountAndRecoveryPath() {
        XCTAssertEqual(
            AppState.bulkConfirmationMessage(for: .moveToTrash, matchCount: 1, isPartial: false),
            "Move 1 message to Trash? You can recover them from Trash."
        )
        XCTAssertEqual(
            AppState.bulkConfirmationMessage(for: .archive, matchCount: 12, isPartial: false),
            "Archive 12 messages? You can find them in the Archive folder."
        )
    }

    /// A capped scan knows only a lower bound, so the confirmation must not
    /// imply an exact count.
    func testPartialPreviewIsWordedAsALowerBound() {
        XCTAssertEqual(
            AppState.bulkConfirmationMessage(for: .markRead, matchCount: 5_000, isPartial: true),
            "Mark at least 5000 messages as read?"
        )
    }

    func testCompletionMessageIsSingularForOneMessage() {
        XCTAssertEqual(
            AppState.bulkCompletionMessage(for: MailBulkResult(action: .archive, affectedCount: 1)),
            "Archived 1 message."
        )
    }
}
