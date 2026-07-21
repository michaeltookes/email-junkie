import EmailJunkieMail
import Foundation

/// A mail provider that models server-side search over a fixed message list,
/// paging by `(offset, limit)` — for exercising the mailbox browser (item 40).
/// Kept in its own file so `AppStateTestDoubles` stays within the length limit.
final class PagingSearchMailProvider: MailProvider, @unchecked Sendable {
    var allMessages: [MailMessage]
    var searchError: MailError?
    private(set) var searchCallCount = 0
    private(set) var lastCriteria: MailSearchCriteria?
    private(set) var lastMailbox: Mailbox?
    private(set) var lastOffset: Int?
    private(set) var lastLimit: Int?

    init(allMessages: [MailMessage]) {
        self.allMessages = allMessages
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

    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        searchCallCount += 1
        lastCriteria = criteria
        lastMailbox = mailbox
        lastOffset = offset
        lastLimit = limit
        if let searchError { throw searchError }

        let matchingMessages = allMessages.filter { message in
            criteria.maximumUID.map { message.id <= $0 } ?? true
        }
        let total = matchingMessages.count
        guard offset < total, limit > 0 else {
            return MailSearchResult(messages: [], totalMatches: total, offset: offset, hasMore: false)
        }
        let end = min(offset + limit, total)
        return MailSearchResult(
            messages: Array(matchingMessages[offset..<end]),
            totalMatches: total,
            offset: offset,
            hasMore: end < total
        )
    }
}
