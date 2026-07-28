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
    /// **Fails open:** if the freshness check itself errors (transient search
    /// failure, a provider that can't search, an unknown source mailbox), it
    /// returns `.fresh` so the check never becomes a new way for a valid send to
    /// be blocked.
    func threadStalenessVerdict(
        for draft: Draft,
        credentials: MailAccountCredentials
    ) async -> StaleThreadVerdict {
        guard let mailbox = Self.sourceMailbox(for: draft) else { return .fresh }
        let subject = StaleThreadCheck.searchSubject(for: draft.sourceSubject)
        guard !subject.isEmpty else { return .fresh }

        do {
            let thread = try await mailProvider.searchMessages(
                credentials,
                mailbox: mailbox,
                criteria: MailSearchCriteria(subject: subject),
                offset: 0,
                limit: threadInspectionLimit
            )
            let sent = try await mailProvider.searchMessages(
                credentials,
                mailbox: .sent,
                criteria: MailSearchCriteria(subject: subject, since: Self.dayFloor(draft.generatedAt)),
                offset: 0,
                limit: threadInspectionLimit
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
            return .fresh
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
