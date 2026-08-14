import SentwiseMail
import Foundation

private enum ThreadInspectionPageDecision {
    case continuePaging
    case stop(hasMoreRelevantMessages: Bool)
}

/// Stale-thread / conflict detection before send (item 12). Just before a draft
/// is sent or saved, the source thread is re-fetched and compared to when the
/// draft was generated; if it changed, dispatch is blocked and the user is warned
/// so an approved reply is never sent into a conversation that moved on.
extension AppState {

    /// How many thread messages to pull when re-checking freshness. A thread
    /// almost never exceeds this; if it does, the search reports `hasMore` and the
    /// evaluator avoids over-claiming "source missing".
    var threadInspectionLimit: Int { 50 }

    /// Blank/prefix-only subjects cannot use IMAP `SUBJECT` search, so the
    /// fallback scans recent mailbox pages. Keep that broad scan bounded.
    var blankSubjectInspectionPageLimit: Int { 4 }

    /// Exact header searches are used only to follow a known thread chain across
    /// subject edits, so keep their breadth bounded too.
    var linkedHeaderInspectionSearchLimit: Int { 12 }

    /// Re-checks a draft's target thread immediately before dispatch. Returns
    /// `.fresh` when the send is safe, or `.stale(reason)` when the source was
    /// archived/deleted, a newer reply arrived, or the user already replied.
    ///
    /// **Fails open:** if the source-thread search itself errors (transient search
    /// failure, a provider that can't search, an unknown source mailbox), it
    /// returns `.fresh` so the check never becomes a new way for a valid send to
    /// be blocked. If only the Sent search fails, source-thread conflicts are still
    /// honored and the unavailable Sent result is treated as empty.
    func threadStalenessVerdict(
        for draft: Draft,
        credentials: MailAccountCredentials
    ) async -> StaleThreadVerdict {
        guard let mailbox = Self.sourceMailbox(for: draft) else { return .fresh }
        let subject = StaleThreadCheck.searchSubject(for: draft.sourceSubject)

        let thread: MailSearchResult
        do {
            thread = try await sourceThreadInspectionResult(
                credentials,
                mailbox: mailbox,
                subject: subject,
                draft: draft
            )
        } catch {
            return .fresh
        }

        let sentSearchStart = Self.dayFloor(draft.generatedAt)
        do {
            let relatedMessageIDs = StaleThreadCheck.relatedMessageIDSearchValues(
                draft: draft,
                threadMessages: thread.messages
            )
            let sent = try await sentThreadInspectionResult(
                credentials,
                subject: subject,
                since: sentSearchStart,
                draft: draft,
                relatedMessageIDs: relatedMessageIDs
            )
            let postGenerationSent = sent.messages.filter {
                Self.isMessage($0, onOrAfterGenerationDate: draft.generatedAt)
            }
            return StaleThreadCheck.verdict(
                draft: draft,
                threadMessages: thread.messages,
                threadTruncated: thread.hasMore,
                sentReplies: postGenerationSent
            )
        } catch {
            return StaleThreadCheck.verdict(
                draft: draft,
                threadMessages: thread.messages,
                threadTruncated: thread.hasMore,
                sentReplies: []
            )
        }
    }

    func sourceThreadInspectionResult(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        subject: String,
        draft: Draft
    ) async throws -> MailSearchResult {
        let sourcePageDecision: ([MailMessage]) -> ThreadInspectionPageDecision = { page in
            if page.contains(where: { Self.isSourceMessage($0, for: draft) }) {
                return .stop(hasMoreRelevantMessages: false)
            }
            if page.contains(where: { Self.isAtOrBeforeSourceUID($0, for: draft) }) {
                return .stop(hasMoreRelevantMessages: false)
            }
            return .continuePaging
        }

        let primary: MailSearchResult
        if subject.isEmpty {
            primary = try await pagedBlankSubjectInspectionResult(
                credentials,
                mailbox: mailbox,
                maxPages: blankSubjectInspectionPageLimit,
                pageDecision: sourcePageDecision
            )
        } else {
            primary = try await pagedSubjectInspectionResult(
                credentials,
                mailbox: mailbox,
                criteria: MailSearchCriteria(subject: subject),
                pageDecision: sourcePageDecision
            )
        }

        let seedMessageIDs = StaleThreadCheck.relatedMessageIDSearchValues(
            draft: draft,
            threadMessages: primary.messages
        )
        let supplemental = await supplementalHeaderInspectionResult(
            credentials,
            mailbox: mailbox,
            seedMessageIDs: seedMessageIDs,
            includeSourceMessages: true
        )
        return Self.mergedInspectionResult(primary, supplemental)
    }

    private func sentThreadInspectionResult(
        _ credentials: MailAccountCredentials,
        subject: String,
        since: Date,
        draft: Draft,
        relatedMessageIDs: Set<String>
    ) async throws -> MailSearchResult {
        let primary: MailSearchResult
        if subject.isEmpty {
            primary = try await pagedBlankSubjectInspectionResult(
                credentials,
                mailbox: .sent,
                pageDecision: { page in
                    if Self.pageMayContainPostGenerationMessages(page, generationDate: draft.generatedAt) {
                        return .continuePaging
                    }
                    return .stop(hasMoreRelevantMessages: false)
                }
            )
        } else {
            primary = try await pagedSubjectInspectionResult(
                credentials,
                mailbox: .sent,
                criteria: MailSearchCriteria(subject: subject, since: since),
                pageDecision: { page in
                    if Self.pageMayContainPostGenerationMessages(page, generationDate: draft.generatedAt) {
                        return .continuePaging
                    }
                    return .stop(hasMoreRelevantMessages: false)
                }
            )
        }

        let supplemental = await supplementalHeaderInspectionResult(
            credentials,
            mailbox: .sent,
            seedMessageIDs: relatedMessageIDs,
            since: since,
            includeSourceMessages: false
        )
        return Self.mergedInspectionResult(primary, supplemental)
    }

    private func pagedSubjectInspectionResult(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria baseCriteria: MailSearchCriteria,
        maxPages: Int? = nil,
        pageDecision: ([MailMessage]) -> ThreadInspectionPageDecision
    ) async throws -> MailSearchResult {
        let pageSize = max(1, threadInspectionLimit)
        var criteria = baseCriteria
        var offset = 0
        var snapshotTotalMatches: Int?
        var snapshotMaximumUID: UInt32?
        var messages: [MailMessage] = []
        var hasMore = false
        var pagesFetched = 0

        while true {
            let page = try await mailProvider.searchMessages(
                credentials,
                mailbox: mailbox,
                criteria: criteria,
                offset: offset,
                limit: pageSize
            )
            if snapshotTotalMatches == nil {
                snapshotTotalMatches = page.totalMatches
                snapshotMaximumUID = page.messages.map(\.id).max()
            }
            messages.append(contentsOf: page.messages)
            hasMore = page.hasMore
            pagesFetched += 1

            switch pageDecision(page.messages) {
            case .stop(let hasMoreRelevantMessages):
                hasMore = hasMoreRelevantMessages
                return MailSearchResult(
                    messages: messages,
                    totalMatches: snapshotTotalMatches ?? page.totalMatches,
                    offset: 0,
                    hasMore: hasMore
                )
            case .continuePaging:
                break
            }

            if !page.hasMore || page.messages.isEmpty || Self.hasReachedPageLimit(maxPages, pagesFetched: pagesFetched) {
                return MailSearchResult(
                    messages: messages,
                    totalMatches: snapshotTotalMatches ?? page.totalMatches,
                    offset: 0,
                    hasMore: hasMore
                )
            }
            if criteria.maximumUID == nil {
                criteria.maximumUID = snapshotMaximumUID
            }
            offset += pageSize
        }
    }

    private func pagedBlankSubjectInspectionResult(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        maxPages: Int? = nil,
        pageDecision: ([MailMessage]) -> ThreadInspectionPageDecision
    ) async throws -> MailSearchResult {
        let pageSize = max(1, threadInspectionLimit)
        var offset = 0
        var snapshotMessageCount: Int?
        var messages: [MailMessage] = []
        var hasMore = false
        var pagesFetched = 0

        while true {
            let page = try await mailProvider.fetchMessagePage(
                credentials,
                mailbox: mailbox,
                offset: offset,
                limit: pageSize,
                snapshotMessageCount: snapshotMessageCount
            )
            if snapshotMessageCount == nil {
                snapshotMessageCount = page.totalMatches
            }
            messages.append(contentsOf: page.messages)
            hasMore = page.hasMore
            pagesFetched += 1

            switch pageDecision(page.messages) {
            case .stop(let hasMoreRelevantMessages):
                hasMore = hasMoreRelevantMessages
                return MailSearchResult(
                    messages: messages,
                    totalMatches: snapshotMessageCount ?? page.totalMatches,
                    offset: 0,
                    hasMore: hasMore
                )
            case .continuePaging:
                break
            }

            if !page.hasMore || page.messages.isEmpty || Self.hasReachedPageLimit(maxPages, pagesFetched: pagesFetched) {
                return MailSearchResult(
                    messages: messages,
                    totalMatches: snapshotMessageCount ?? page.totalMatches,
                    offset: 0,
                    hasMore: hasMore
                )
            }
            offset += pageSize
        }
    }

    func exactHeaderInspectionResult(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        field: String,
        value: String,
        since: Date? = nil
    ) async throws -> MailSearchResult {
        try await mailProvider.searchMessages(
            credentials,
            mailbox: mailbox,
            criteria: MailSearchCriteria(
                headers: [MailHeaderSearch(field: field, value: value)],
                since: since
            ),
            offset: 0,
            limit: threadInspectionLimit
        )
    }

    func supplementalHeaderInspectionResult(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        seedMessageIDs: Set<String>,
        since: Date? = nil,
        includeSourceMessages: Bool
    ) async -> MailSearchResult {
        let seeds = seedMessageIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !seeds.isEmpty else { return .empty(offset: 0) }

        var pending = Array(seeds).sorted()
        var searched = Set<String>()
        var searchesRun = 0
        var merged = MailSearchResult.empty(offset: 0)

        while let messageID = pending.first, searchesRun < linkedHeaderInspectionSearchLimit {
            pending.removeFirst()
            guard searched.insert(messageID).inserted else { continue }

            if includeSourceMessages, searchesRun < linkedHeaderInspectionSearchLimit {
                if let source = try? await exactHeaderInspectionResult(
                    credentials,
                    mailbox: mailbox,
                    field: "Message-ID",
                    value: messageID,
                    since: since
                ) {
                    searchesRun += 1
                    merged = Self.mergedInspectionResult(merged, source)
                    appendNewMessageIDs(from: source.messages, searched: searched, pending: &pending)
                }
            }

            guard searchesRun < linkedHeaderInspectionSearchLimit else { break }
            if let replies = try? await exactHeaderInspectionResult(
                credentials,
                mailbox: mailbox,
                field: "In-Reply-To",
                value: messageID,
                since: since
            ) {
                searchesRun += 1
                merged = Self.mergedInspectionResult(merged, replies)
                appendNewMessageIDs(from: replies.messages, searched: searched, pending: &pending)
            }
        }

        return merged
    }

    static func mergedInspectionResult(
        _ primary: MailSearchResult,
        _ supplemental: MailSearchResult
    ) -> MailSearchResult {
        guard !supplemental.messages.isEmpty else {
            return MailSearchResult(
                messages: primary.messages,
                totalMatches: primary.totalMatches,
                offset: primary.offset,
                hasMore: primary.hasMore || supplemental.hasMore
            )
        }

        var messages = primary.messages
        var seen = Set(messages.map(messageDeduplicationKey))
        for message in supplemental.messages where seen.insert(messageDeduplicationKey(message)).inserted {
            messages.append(message)
        }
        return MailSearchResult(
            messages: messages,
            totalMatches: messages.count,
            offset: 0,
            hasMore: primary.hasMore || supplemental.hasMore
        )
    }

    private static func messageDeduplicationKey(_ message: MailMessage) -> String {
        if let messageID = StaleThreadCheck.messageIDSearchValue(message.messageID) {
            return "message-id:\(messageID)"
        }
        let validity = message.uidValidity.map(String.init) ?? "?"
        return "uid:\(validity):\(message.id)"
    }

    private func appendNewMessageIDs(
        from messages: [MailMessage],
        searched: Set<String>,
        pending: inout [String]
    ) {
        for message in messages {
            guard let messageID = StaleThreadCheck.messageIDSearchValue(message.messageID) else { continue }
            guard !searched.contains(messageID), !pending.contains(messageID) else { continue }
            pending.append(messageID)
        }
    }

    private static func isSourceMessage(_ message: MailMessage, for draft: Draft) -> Bool {
        guard message.id == draft.id else { return false }
        guard let draftUIDValidity = draft.sourceUIDValidity,
              let messageUIDValidity = message.uidValidity else {
            return true
        }
        return draftUIDValidity == messageUIDValidity
    }

    private static func isAtOrBeforeSourceUID(_ message: MailMessage, for draft: Draft) -> Bool {
        guard isUIDComparable(message, for: draft) else { return false }
        return message.id <= draft.id
    }

    private static func isUIDComparable(_ message: MailMessage, for draft: Draft) -> Bool {
        guard let draftUIDValidity = draft.sourceUIDValidity,
              let messageUIDValidity = message.uidValidity else {
            return true
        }
        return draftUIDValidity == messageUIDValidity
    }

    private static func hasReachedPageLimit(_ maxPages: Int?, pagesFetched: Int) -> Bool {
        guard let maxPages else { return false }
        return pagesFetched >= max(1, maxPages)
    }

    private static func pageMayContainPostGenerationMessages(
        _ messages: [MailMessage],
        generationDate: Date
    ) -> Bool {
        messages.contains { message in
            guard let messageDate = parsedMessageDate(message.date) else { return true }
            return messageDate >= generationDate
        }
    }

    /// Reverse-maps a draft's persisted source-mailbox tag to a `Mailbox`.
    /// Returns `nil` when the tag is missing so the caller skips the freshness
    /// check rather than guessing at the wrong mailbox.
    static func sourceMailbox(for draft: Draft) -> Mailbox? {
        guard let tag = draft.sourceMailbox?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tag.isEmpty else {
            return nil
        }
        switch tag {
        case Mailbox.inbox.imapName: return .inbox
        case Mailbox.allMail.imapName: return .allMail
        case Mailbox.trash.imapName: return .trash
        case Mailbox.sent.imapName: return .sent
        case Mailbox.drafts.imapName: return .drafts
        default: return .named(tag)
        }
    }

    /// Local midnight of `date`, for an inclusive IMAP `SINCE` bound that captures
    /// same-day replies made after the draft was generated.
    static func dayFloor(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// Sent searches can only use IMAP's day-granularity `SINCE`; this exact
    /// envelope-date filter prevents same-day messages sent before generation
    /// from blocking a later draft. A related Sent message with an unparseable
    /// date is kept so stale-thread protection does not miss a manual reply.
    static func isMessage(_ message: MailMessage, onOrAfterGenerationDate generationDate: Date) -> Bool {
        guard let messageDate = parsedMessageDate(message.date) else { return true }
        return messageDate >= generationDate
    }
}
