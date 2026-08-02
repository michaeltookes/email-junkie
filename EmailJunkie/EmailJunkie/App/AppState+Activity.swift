import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "ActivityHistory")

/// Activity-history recording and linkage on `AppState` (item 21). The history is
/// a bounded, persisted log of what the assistant did — drafts created, approvals
/// sent/saved, denials, reply-worthiness skips, stale-thread warnings, and send
/// failures. It stores **metadata only** (sender/subject/reason), never message
/// bodies or draft content, and links back to a source message when the
/// account/mailbox still match the connected account.
extension AppState {

    // MARK: - Recording

    /// Records `event` at the front of the history (newest first), evicting the
    /// oldest entries past `activityEventLogLimit`, and persists the result.
    func recordActivity(_ event: ActivityEvent) {
        activityEvents.insert(event, at: 0)
        if activityEvents.count > activityEventLogLimit {
            activityEvents.removeLast(activityEvents.count - activityEventLogLimit)
        }
        persistence.saveActivityEvents(activityEvents)
        logger.info("Recorded activity event (\(event.kind.rawValue, privacy: .public))")
    }

    /// Records a draft-scoped event (created / sent / saved / denied / stale /
    /// send-failed) from a `Draft`, capturing linkage metadata from its source.
    func recordDraftActivity(
        _ kind: ActivityEventKind,
        for draft: Draft,
        staleReason: StaleThreadReason? = nil,
        detail: String? = nil
    ) {
        recordActivity(ActivityEvent(
            kind: kind,
            account: draft.sourceAccountEmail,
            mailbox: draft.sourceMailbox,
            sender: draft.sourceFrom?.name ?? draft.sourceFrom?.email,
            subject: draft.sourceSubject,
            staleReason: staleReason,
            detail: detail,
            messageUID: draft.id,
            messageUIDValidity: draft.sourceUIDValidity
        ))
    }

    /// Records a durable skip event from a `SkippedMessage` (item 17). The
    /// in-memory `skippedMessages` override entry still carries the full message
    /// for "Draft anyway"; this metadata-only event survives restart.
    func recordSkipActivity(for entry: SkippedMessage) {
        recordActivity(ActivityEvent(
            kind: .skipped,
            account: entry.account,
            mailbox: entry.mailbox.imapName,
            sender: entry.senderDisplay,
            subject: entry.subject,
            skipReason: entry.reason,
            messageUID: entry.message.id,
            messageUIDValidity: entry.message.uidValidity
        ))
    }

    /// Clears the entire activity history and persists the empty log.
    func clearActivityHistory() {
        activityEvents.removeAll()
        persistence.saveActivityEvents(activityEvents)
    }

    // MARK: - Link back to the source message

    /// Whether the history entry can open its source message: it carries a UID and
    /// the still-connected account matches the one the event was recorded under.
    /// Mailbox naming is provider-specific, so linkage reuses the existing
    /// fetch/preview path rather than building new IMAP machinery.
    func canOpenActivityEvent(_ event: ActivityEvent) -> Bool {
        guard event.messageUID != nil, isAccountConnected, let account = event.account else {
            return false
        }
        let connected = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.caseInsensitiveCompare(connected) == .orderedSame
    }

    /// Opens the source message's readable-body preview for a history entry, when
    /// linkage is possible. Reuses `previewBody`, returning the fetched preview so
    /// the caller can present it in a sheet. Returns `nil` when linkage isn't
    /// available or the fetch fails.
    @discardableResult
    func openActivityEvent(_ event: ActivityEvent) async -> MailBodyPreview? {
        guard canOpenActivityEvent(event), let uid = event.messageUID else { return nil }
        let message = MailMessage(
            id: uid,
            uidValidity: event.messageUIDValidity,
            from: nil,
            subject: event.subject ?? "",
            date: ""
        )
        let mailbox = event.mailbox.map(Self.mailbox(forStableName:)) ?? .inbox
        return await previewBody(for: message, mailbox: mailbox)
    }

    /// Maps a persisted stable `imapName` back to a `Mailbox` case so linkage
    /// re-fetches through the same provider-aware naming resolution used elsewhere.
    static func mailbox(forStableName name: String) -> Mailbox {
        switch name {
        case Mailbox.inbox.imapName: return .inbox
        case Mailbox.sent.imapName: return .sent
        case Mailbox.drafts.imapName: return .drafts
        case Mailbox.allMail.imapName: return .allMail
        case Mailbox.trash.imapName: return .trash
        default: return .named(name)
        }
    }
}
