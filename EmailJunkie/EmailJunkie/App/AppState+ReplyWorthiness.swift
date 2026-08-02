import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "ReplyWorthiness")

/// Reply-worthiness gating on `AppState` (item 17): the watcher runs this before
/// the LLM draft call so obvious non-replyable mail (no-reply senders, bulk/list
/// mail, automated notifications, calendar invites) never costs a draft. The
/// decision logic itself lives in the pure `ReplyWorthiness` evaluator; this file
/// gathers the signals, records skips, and provides the user override.
extension AppState {

    /// Judges `message` and returns the skip reason, or `nil` when it is worth a
    /// draft. Fetches the bounded header fields the ENVELOPE lacks; if that fetch
    /// fails, evaluation falls back to sender-only signals — conservative, since a
    /// no-reply sender is still caught and a missing header only errs toward
    /// drafting.
    func replyWorthinessSkipReason(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async -> ReplyWorthinessReason? {
        let headers = await fetchReplyWorthinessHeaders(message, credentials: credentials, mailbox: mailbox)
        let signals = ReplyWorthinessSignals(senderEmail: message.from?.email, headers: headers)
        return ReplyWorthiness.evaluate(signals).skipReason
    }

    /// Best-effort header-fields fetch for the worthiness check. Never throws:
    /// on any failure it returns empty fields so the caller degrades to
    /// sender-only evaluation rather than blocking the poll.
    private func fetchReplyWorthinessHeaders(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async -> MailHeaderFields {
        do {
            return try await mailProvider.fetchHeaderFields(
                credentials,
                mailbox: mailbox,
                uid: message.id,
                expectedUIDValidity: message.uidValidity
            )
        } catch {
            logger.error("Reply-worthiness header fetch failed; evaluating sender only: \(error.localizedDescription)")
            return MailHeaderFields()
        }
    }

    // MARK: - Skip log

    /// Records a skipped message on the bounded, observable skip log (newest
    /// first). De-dupes by identity so the same message never appears twice.
    func recordSkip(
        _ message: MailMessage,
        reason: ReplyWorthinessReason,
        account: String,
        mailbox: Mailbox
    ) {
        let entry = SkippedMessage(
            message: message,
            mailbox: mailbox,
            account: account,
            reason: reason
        )
        skippedMessages.removeAll { $0.id == entry.id }
        skippedMessages.insert(entry, at: 0)
        if skippedMessages.count > skippedMessageLogLimit {
            skippedMessages.removeLast(skippedMessages.count - skippedMessageLogLimit)
        }
        logger.info("Skipped message (\(reason.rawValue, privacy: .public)) from log; \(self.skippedMessages.count) entries")
    }

    /// Removes a single entry from the skip log.
    func removeSkippedMessage(_ entry: SkippedMessage) {
        skippedMessages.removeAll { $0.id == entry.id }
    }

    /// Clears the whole skip log.
    func clearSkippedMessages() {
        skippedMessages.removeAll()
    }

    // MARK: - Override

    /// Forces a draft for a message the worthiness gate skipped. Routes through
    /// the normal draft pipeline (`draftAndEnqueue`), bypassing only the
    /// worthiness check, then marks the message handled and drops it from the
    /// skip log. `requireWatching` is `false` so the override works from the skip
    /// log regardless of watch state.
    @discardableResult
    func forceDraftSkippedMessage(_ entry: SkippedMessage) async -> Bool {
        watchError = nil

        let credentials = mailCredentials
        guard credentials.isComplete else {
            watchError = "Connect an email account first."
            return false
        }
        guard credentials.email.caseInsensitiveCompare(entry.account) == .orderedSame else {
            watchError = "That message belongs to a different account than the one connected."
            return false
        }
        guard canGenerateDraft else {
            watchError = "Connect an AI provider first."
            return false
        }

        do {
            let enqueued = try await draftAndEnqueue(
                entry.message,
                mailbox: entry.mailbox,
                requireWatching: false
            )
            guard enqueued else { return false }
            markProcessed(entry.message, account: credentials.email, mailbox: entry.mailbox)
            removeSkippedMessage(entry)
            return true
        } catch {
            watchError = Self.draftMessage(for: error)
            logger.error("Force-draft of skipped message failed: \(error.localizedDescription)")
            return false
        }
    }
}
