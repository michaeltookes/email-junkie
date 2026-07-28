import EmailJunkieMail
import Foundation

/// Stale-thread / conflict detection before send (item 12). Just before a draft
/// is sent or saved, the source thread is re-fetched and compared to when the
/// draft was generated; if it changed, dispatch is blocked and the user is warned
/// so an approved reply is never sent into a conversation that moved on.
extension AppState {

    /// How many thread messages to pull when re-checking freshness. A thread
    /// almost never exceeds this; if it does, the search reports `hasMore` and the
    /// evaluator avoids over-claiming "source missing".
    var threadInspectionLimit: Int { 50 }

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
            let sent = try await sentThreadInspectionResult(
                credentials,
                subject: subject,
                since: sentSearchStart,
                draft: draft
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
        if subject.isEmpty {
            return try await pagedBlankSubjectInspectionResult(
                credentials,
                mailbox: mailbox,
                shouldStopAfterPage: { page in
                    page.contains { Self.isSourceMessage($0, for: draft) }
                }
            )
        }
        return try await mailProvider.searchMessages(
            credentials,
            mailbox: mailbox,
            criteria: MailSearchCriteria(subject: subject),
            offset: 0,
            limit: threadInspectionLimit
        )
    }

    private func sentThreadInspectionResult(
        _ credentials: MailAccountCredentials,
        subject: String,
        since: Date,
        draft: Draft
    ) async throws -> MailSearchResult {
        if subject.isEmpty {
            return try await pagedBlankSubjectInspectionResult(
                credentials,
                mailbox: .sent,
                shouldStopAfterPage: { page in
                    !Self.pageMayContainPostGenerationMessages(page, generationDate: draft.generatedAt)
                }
            )
        }
        return try await mailProvider.searchMessages(
            credentials,
            mailbox: .sent,
            criteria: MailSearchCriteria(subject: subject, since: since),
            offset: 0,
            limit: threadInspectionLimit
        )
    }

    private func pagedBlankSubjectInspectionResult(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        shouldStopAfterPage: ([MailMessage]) -> Bool
    ) async throws -> MailSearchResult {
        let pageSize = max(1, threadInspectionLimit)
        var offset = 0
        var snapshotMessageCount: Int?
        var messages: [MailMessage] = []
        var hasMore = false

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

            if shouldStopAfterPage(page.messages) || !page.hasMore || page.messages.isEmpty {
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

    private static func isSourceMessage(_ message: MailMessage, for draft: Draft) -> Bool {
        guard message.id == draft.id else { return false }
        guard let draftUIDValidity = draft.sourceUIDValidity,
              let messageUIDValidity = message.uidValidity else {
            return true
        }
        return draftUIDValidity == messageUIDValidity
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
    /// from blocking a later draft.
    static func isMessage(_ message: MailMessage, onOrAfterGenerationDate generationDate: Date) -> Bool {
        guard let messageDate = parsedMessageDate(message.date) else { return false }
        return messageDate >= generationDate
    }
}
