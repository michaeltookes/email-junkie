import EmailJunkieMail
import Foundation

/// The mailbox + criteria used to produce the currently displayed result set.
struct MailboxBrowserQuery: Equatable {
    var mailbox: Mailbox
    var criteria: MailSearchCriteria

    func capped(at maximumUID: UInt32?) -> MailboxBrowserQuery {
        var capped = self
        capped.criteria.maximumUID = maximumUID
        return capped
    }

    func nextPage(after lastUID: UInt32?) -> MailboxBrowserQuery? {
        guard let lastUID, lastUID > 1 else { return nil }
        let cursorMaximumUID = lastUID - 1
        return capped(at: criteria.maximumUID.map { min($0, cursorMaximumUID) } ?? cursorMaximumUID)
    }
}

/// State for the mailbox browser window (item 40): search inputs, one page of
/// results, and paging status. Grouped into a single value so `AppState` stays
/// compact; SwiftUI binds into the individual fields.
struct MailboxBrowserState: Equatable {

    // MARK: Inputs

    var mailbox: Mailbox = .inbox
    var keyword: String = ""
    var sender: String = ""
    var readState: MailReadState = .any
    /// Date filters are opt-in so an untouched browser searches all dates.
    var useSinceFilter = false
    var since = Date()
    var useBeforeFilter = false
    var before = Date()

    // MARK: Results / status

    /// Results accumulated across the pages loaded so far, newest first.
    var results: [MailMessage] = []
    var isSearching = false
    var isLoadingMore = false
    var error: String?
    var hasMore = false
    var totalMatches = 0
    /// True once at least one search has completed, so the UI can tell "no
    /// search yet" from "no matches".
    var hasSearched = false
    /// Query that produced `results`; used so pagination and row actions remain
    /// attached to those rows even if the editable controls change afterward.
    var resultQuery: MailboxBrowserQuery?

    /// The IMAP search criteria described by the current inputs.
    var criteria: MailSearchCriteria {
        MailSearchCriteria(
            text: Self.trimmedOrNil(keyword),
            from: Self.trimmedOrNil(sender),
            since: useSinceFilter ? since : nil,
            before: useBeforeFilter ? before : nil,
            readState: readState
        )
    }

    /// The mailbox search described by the current inputs.
    var query: MailboxBrowserQuery {
        MailboxBrowserQuery(mailbox: mailbox, criteria: criteria)
    }

    private static func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Mailbox-browser actions on `AppState` (item 40). Kept in a separate file so
/// `AppState` stays within the file/type length limits. Each request is guarded
/// by a monotonic generation counter so a stale completion (after an account
/// change or a newer search) never clobbers current state.
extension AppState {

    /// How many results each search page fetches.
    static let mailboxBrowserPageSize = 25

    /// Runs a fresh search from the first page using the current browser inputs.
    func runMailboxSearch() async {
        let requestGeneration = nextBrowserGeneration()
        let query = browser.query
        browser.error = nil
        browser.results = []
        browser.resultQuery = nil
        browser.hasMore = false
        browser.totalMatches = 0
        browser.isLoadingMore = false

        let credentials = mailCredentials
        guard credentials.isComplete else {
            browser.error = "Connect an account first."
            browser.hasSearched = true
            return
        }

        browser.isSearching = true
        defer {
            if browserGeneration == requestGeneration {
                browser.isSearching = false
                browser.hasSearched = true
            }
        }

        do {
            let result = try await mailProvider.searchMessages(
                credentials,
                mailbox: query.mailbox,
                criteria: query.criteria,
                offset: 0,
                limit: Self.mailboxBrowserPageSize
            )
            guard isCurrentBrowserRequest(requestGeneration, credentials: credentials) else { return }
            browser.results = result.messages
            browser.resultQuery = query.capped(at: result.messages.map(\.id).max())
            browser.hasMore = result.hasMore
            browser.totalMatches = result.totalMatches
        } catch {
            guard isCurrentBrowserRequest(requestGeneration, credentials: credentials) else { return }
            browser.error = Self.message(for: error)
        }
    }

    /// Loads and appends the next page of results (pagination). No-op unless a
    /// prior search reported more results and nothing else is in flight.
    func loadMoreMailboxResults() async {
        guard browser.hasMore, !browser.isSearching, !browser.isLoadingMore else { return }
        guard let query = browser.resultQuery else { return }
        guard let pageQuery = query.nextPage(after: browser.results.last?.id) else {
            browser.hasMore = false
            return
        }
        let requestGeneration = browserGeneration
        let loadedCount = browser.results.count

        let credentials = mailCredentials
        guard credentials.isComplete else { return }

        browser.error = nil
        browser.isLoadingMore = true
        defer {
            if browserGeneration == requestGeneration {
                browser.isLoadingMore = false
            }
        }

        do {
            let result = try await mailProvider.searchMessages(
                credentials,
                mailbox: pageQuery.mailbox,
                criteria: pageQuery.criteria,
                offset: 0,
                limit: Self.mailboxBrowserPageSize
            )
            guard isCurrentBrowserRequest(requestGeneration, credentials: credentials) else { return }
            browser.error = nil
            browser.results.append(contentsOf: result.messages)
            browser.hasMore = result.hasMore
            browser.totalMatches = loadedCount + result.totalMatches
        } catch {
            guard isCurrentBrowserRequest(requestGeneration, credentials: credentials) else { return }
            browser.error = Self.message(for: error)
        }
    }

    func nextBrowserGeneration() -> Int {
        browserGeneration += 1
        return browserGeneration
    }

    /// Clears the browser and invalidates any in-flight request when the
    /// connected account changes.
    func resetMailboxBrowserForAccountChange() {
        _ = nextBrowserGeneration()
        browser = MailboxBrowserState()
    }

    private func isCurrentBrowserRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials
    ) -> Bool {
        browserGeneration == requestGeneration && mailCredentials == credentials
    }
}
