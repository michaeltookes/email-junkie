import EmailJunkieMail
import XCTest
@testable import EmailJunkie

/// Tests for the mailbox browser search/paging actions on `AppState` (item 40),
/// driven by an in-memory paging search provider — no network.
@MainActor
final class AppStateMailboxBrowserTests: XCTestCase {

    private func messages(_ count: Int) -> [MailMessage] {
        // Newest first (descending UID), mirroring a real search page.
        (0..<count).reversed().map { index in
            MailMessage(
                id: UInt32(100 + index),
                uidValidity: 1,
                from: MailAddress(name: "Sender \(index)", email: "sender\(index)@x.com"),
                subject: "Subject \(index)",
                date: "",
                messageID: "<\(index)@x.com>"
            )
        }
    }

    private func makeAppState(
        provider: MailProvider,
        connected: Bool = true
    ) -> AppState {
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

    // MARK: - First page

    func testSearchLoadsFirstPageNewestFirst() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)

        await appState.runMailboxSearch()

        XCTAssertEqual(appState.browser.results.count, AppState.mailboxBrowserPageSize)
        XCTAssertEqual(appState.browser.results.first?.id, 129)  // newest
        XCTAssertEqual(appState.browser.totalMatches, 30)
        XCTAssertTrue(appState.browser.hasMore)
        XCTAssertTrue(appState.browser.hasSearched)
        XCTAssertFalse(appState.browser.isSearching)
        XCTAssertNil(appState.browser.error)
        XCTAssertEqual(appState.browser.resultQuery?.mailbox, .inbox)
        // The unfiltered view pages by offset (bounded sequence fetch, item 45),
        // so its query carries no UID ceiling.
        XCTAssertEqual(appState.browser.resultQuery?.criteria, MailSearchCriteria())
        XCTAssertEqual(appState.browser.sequenceSnapshotMessageCount, 30)
        XCTAssertEqual(appState.browser.sequencePageOffset, AppState.mailboxBrowserPageSize)
        XCTAssertEqual(provider.lastOffset, 0)
        XCTAssertNil(provider.lastSnapshotMessageCount)
    }

    // MARK: - Pagination

    func testLoadMoreAppendsNextPage() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)

        await appState.runMailboxSearch()
        await appState.loadMoreMailboxResults()

        XCTAssertEqual(appState.browser.results.count, 30)
        XCTAssertFalse(appState.browser.hasMore)
        // Unfiltered pagination advances by offset, not a UID ceiling.
        XCTAssertEqual(provider.lastOffset, 25)
        XCTAssertEqual(provider.lastSnapshotMessageCount, 30)
        XCTAssertNil(provider.lastCriteria?.maximumUID)
        XCTAssertEqual(provider.searchCallCount, 2)
        XCTAssertEqual(appState.browser.sequencePageOffset, 50)
        // No duplicates: ids are unique and contiguous.
        XCTAssertEqual(Set(appState.browser.results.map(\.id)).count, 30)
    }

    func testUnfilteredLoadMoreUsesSequenceSnapshotWhenNewMessagesArrive() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)

        await appState.runMailboxSearch()
        provider.allMessages.insert(
            MailMessage(
                id: 130,
                uidValidity: 1,
                from: MailAddress(name: "New", email: "new@x.com"),
                subject: "New mail",
                date: "",
                messageID: "<new@x.com>"
            ),
            at: 0
        )
        await appState.loadMoreMailboxResults()

        XCTAssertEqual(provider.lastOffset, 25)
        XCTAssertEqual(provider.lastSnapshotMessageCount, 30)
        XCTAssertEqual(appState.browser.totalMatches, 30)
        XCTAssertEqual(appState.browser.results.count, 30)
        XCTAssertFalse(appState.browser.results.contains { $0.id == 130 })
        XCTAssertEqual(appState.browser.results.suffix(5).map(\.id), [104, 103, 102, 101, 100])
        XCTAssertEqual(Set(appState.browser.results.map(\.id)).count, 30)
    }

    func testUnfilteredLoadMoreUsesSequenceSnapshotWhenLoadedMessageIsDeleted() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)

        await appState.runMailboxSearch()
        provider.allMessages.removeAll { $0.id == 120 }
        await appState.loadMoreMailboxResults()

        XCTAssertEqual(provider.lastOffset, 25)
        XCTAssertEqual(provider.lastSnapshotMessageCount, 30)
        XCTAssertEqual(appState.browser.totalMatches, 30)
        XCTAssertEqual(appState.browser.results.count, 30)
        XCTAssertEqual(appState.browser.results.suffix(5).map(\.id), [104, 103, 102, 101, 100])
        XCTAssertEqual(Set(appState.browser.results.map(\.id)).count, 30)
    }

    func testLoadMoreUsesQueryFromDisplayedResults() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)
        appState.browser.mailbox = .inbox
        appState.browser.keyword = "  invoice  "

        await appState.runMailboxSearch()
        appState.browser.mailbox = .sent
        appState.browser.keyword = "changed"
        appState.browser.sender = "other@example.com"
        await appState.loadMoreMailboxResults()

        XCTAssertEqual(provider.lastMailbox, .inbox)
        XCTAssertEqual(provider.lastCriteria?.text, "invoice")
        XCTAssertNil(provider.lastCriteria?.from)
        XCTAssertEqual(provider.lastCriteria?.maximumUID, 104)
        XCTAssertEqual(provider.lastOffset, 0)
        XCTAssertEqual(appState.browser.results.count, 30)
    }

    func testLoadMoreUsesStableUIDWindowWhenNewMessagesArrive() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)
        // A filter engages the UID-ceiling paging path (the unfiltered view
        // pages by offset instead — item 45).
        appState.browser.keyword = "mail"
        await appState.runMailboxSearch()

        provider.allMessages.insert(
            MailMessage(
                id: 130,
                uidValidity: 1,
                from: MailAddress(name: "New", email: "new@x.com"),
                subject: "New mail",
                date: "",
                messageID: "<new@x.com>"
            ),
            at: 0
        )
        await appState.loadMoreMailboxResults()

        XCTAssertEqual(provider.lastCriteria?.maximumUID, 104)
        XCTAssertEqual(provider.lastOffset, 0)
        XCTAssertEqual(appState.browser.totalMatches, 30)
        XCTAssertEqual(appState.browser.results.count, 30)
        XCTAssertFalse(appState.browser.results.contains { $0.id == 130 })
        XCTAssertEqual(Set(appState.browser.results.map(\.id)).count, 30)
        XCTAssertEqual(appState.browser.results.last?.id, 100)
    }

    func testLoadMoreUsesCursorWhenLoadedMessageIsDeleted() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)
        // A filter engages the UID-ceiling paging path (item 45).
        appState.browser.keyword = "mail"
        await appState.runMailboxSearch()

        provider.allMessages.removeAll { $0.id == 120 }
        await appState.loadMoreMailboxResults()

        XCTAssertEqual(provider.lastCriteria?.maximumUID, 104)
        XCTAssertEqual(provider.lastOffset, 0)
        XCTAssertEqual(appState.browser.results.suffix(5).map(\.id), [104, 103, 102, 101, 100])
        XCTAssertEqual(Set(appState.browser.results.map(\.id)).count, 30)
        XCTAssertEqual(appState.browser.totalMatches, 30)
    }

    func testLoadMoreRetryClearsPreviousPaginationError() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)
        await appState.runMailboxSearch()

        provider.searchError = .commandFailed("transient failure")
        await appState.loadMoreMailboxResults()

        XCTAssertNotNil(appState.browser.error)
        XCTAssertEqual(appState.browser.results.count, AppState.mailboxBrowserPageSize)
        XCTAssertTrue(appState.browser.hasMore)

        provider.searchError = nil
        await appState.loadMoreMailboxResults()

        XCTAssertNil(appState.browser.error)
        XCTAssertEqual(appState.browser.results.count, 30)
        XCTAssertFalse(appState.browser.hasMore)
    }

    func testLoadMoreIsNoOpWhenNoMoreResults() async {
        let provider = PagingSearchMailProvider(allMessages: messages(5))
        let appState = makeAppState(provider: provider)

        await appState.runMailboxSearch()
        XCTAssertFalse(appState.browser.hasMore)
        await appState.loadMoreMailboxResults()

        XCTAssertEqual(provider.searchCallCount, 1, "load-more must not call search when there is no next page")
    }

    // MARK: - Empty / error

    func testEmptySearchSetsHasSearchedWithNoResults() async {
        let provider = PagingSearchMailProvider(allMessages: [])
        let appState = makeAppState(provider: provider)

        await appState.runMailboxSearch()

        XCTAssertTrue(appState.browser.results.isEmpty)
        XCTAssertEqual(appState.browser.totalMatches, 0)
        XCTAssertFalse(appState.browser.hasMore)
        XCTAssertTrue(appState.browser.hasSearched)
        XCTAssertNil(appState.browser.error)
    }

    func testSearchErrorSurfacesMessage() async {
        let provider = PagingSearchMailProvider(allMessages: messages(3))
        provider.searchError = .commandFailed("boom")
        let appState = makeAppState(provider: provider)

        await appState.runMailboxSearch()

        XCTAssertNotNil(appState.browser.error)
        XCTAssertTrue(appState.browser.results.isEmpty)
        XCTAssertTrue(appState.browser.hasSearched)
    }

    func testSearchWithoutAccountSetsError() async {
        let provider = PagingSearchMailProvider(allMessages: messages(3))
        let appState = makeAppState(provider: provider, connected: false)

        await appState.runMailboxSearch()

        XCTAssertEqual(appState.browser.error, "Connect an account first.")
        XCTAssertEqual(provider.searchCallCount, 0)
    }

    // MARK: - Criteria + mailbox

    func testCriteriaAndMailboxBuiltFromInputs() async {
        let provider = PagingSearchMailProvider(allMessages: messages(3))
        let appState = makeAppState(provider: provider)
        let since = Date(timeIntervalSince1970: 1_700_000_000)

        appState.browser.mailbox = .allMail
        appState.browser.keyword = "  invoice  "
        appState.browser.sender = "alice@x.com"
        appState.browser.readState = .unreadOnly
        appState.browser.useSinceFilter = true
        appState.browser.since = since

        await appState.runMailboxSearch()

        XCTAssertEqual(provider.lastMailbox, .allMail)
        XCTAssertEqual(provider.lastCriteria?.text, "invoice")  // trimmed
        XCTAssertEqual(provider.lastCriteria?.from, "alice@x.com")
        XCTAssertEqual(provider.lastCriteria?.readState, .unreadOnly)
        XCTAssertEqual(provider.lastCriteria?.since, since)
        XCTAssertNil(provider.lastCriteria?.before, "before filter is off")
    }

    func testDisabledDateFilterIsNotSentAsCriteria() async {
        let provider = PagingSearchMailProvider(allMessages: messages(3))
        let appState = makeAppState(provider: provider)

        appState.browser.useSinceFilter = false
        appState.browser.since = Date(timeIntervalSince1970: 1_700_000_000)
        await appState.runMailboxSearch()

        XCTAssertNil(provider.lastCriteria?.since)
        XCTAssertTrue(appState.browser.criteria.isEmpty)
    }

    // MARK: - Reset

    func testAccountChangeResetsBrowser() async {
        let provider = PagingSearchMailProvider(allMessages: messages(30))
        let appState = makeAppState(provider: provider)

        appState.browser.keyword = "hi"
        await appState.runMailboxSearch()
        XCTAssertFalse(appState.browser.results.isEmpty)

        appState.disconnectMail()

        XCTAssertTrue(appState.browser.results.isEmpty)
        XCTAssertEqual(appState.browser.keyword, "")
        XCTAssertFalse(appState.browser.hasSearched)
        XCTAssertEqual(appState.browser.mailbox, .inbox)
    }
}
