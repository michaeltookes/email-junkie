import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "InboxWatcher")

/// Inbox-watcher lifecycle and poll policy on `AppState`. The `InboxWatcher`
/// owns the timer and sleep/wake handling; this file owns *what a poll does*.
extension AppState {

    /// Whether watching can run: an account and an LLM must both be connected.
    var canWatch: Bool {
        isAccountConnected && isLLMConnected
    }

    /// Starts watching if ready — used at launch to auto-resume.
    func startWatchingIfReady() {
        guard canWatch, watchStatus != .watching else { return }
        startWatching()
    }

    /// Begins watching the inbox (schedules polling + an immediate poll).
    func startWatching() {
        guard canWatch else {
            watchError = "Connect an email account and an AI provider before watching."
            return
        }
        watchError = nil
        watchStatus = .watching
        inboxWatcher.start()
        logger.info("Inbox watching started")
    }

    /// Pauses watching; the queue and processed history are kept.
    func pauseWatching() {
        guard watchStatus == .watching else { return }
        watchStatus = .paused
        inboxWatcher.stop()
        logger.info("Inbox watching paused")
    }

    /// Stops watching entirely (e.g. on disconnect); returns to idle.
    func stopWatching() {
        guard watchStatus != .idle else { return }
        watchStatus = .idle
        inboxWatcher.stop()
        logger.info("Inbox watching stopped")
    }

    /// Toggles between watching and paused for the menu-bar control.
    func toggleWatching() {
        switch watchStatus {
        case .watching:
            pauseWatching()
        case .idle, .paused:
            startWatching()
        }
    }

    /// One inbox poll: fetch recent messages, and for each new, replyable one,
    /// generate a draft and enqueue it. The first poll per account/mailbox seeds
    /// a baseline so existing mail is not drafted as newly arrived. A message is
    /// marked processed only after its draft is durably queued.
    func pollInboxOnce() async {
        guard watchStatus == .watching else { return }
        guard canWatch else {
            pauseWatching()
            return
        }
        guard !isPollingInbox else { return }
        isPollingInbox = true
        defer { isPollingInbox = false }

        let credentials = mailCredentials
        let mailbox = Mailbox.inbox
        let messages: [MailMessage]
        do {
            messages = try await mailProvider.fetchRecentMessages(
                credentials,
                mailbox: mailbox,
                limit: watchFetchLimit
            )
        } catch {
            watchError = Self.message(for: error)
            logger.error("Inbox poll fetch failed: \(error.localizedDescription)")
            return
        }
        guard watchStatus == .watching, mailCredentials == credentials else { return }
        watchError = nil

        if seedWatcherBaselineIfNeeded(messages: messages, account: credentials.email, mailbox: mailbox) {
            return
        }

        // Oldest first so enqueued drafts read in chronological order.
        for message in messages.reversed() {
            guard watchStatus == .watching, mailCredentials == credentials else { break }
            await draftMessageIfNeeded(message, credentials: credentials, mailbox: mailbox)
        }
    }

    /// Light replyability gate for the watcher: the message must have a real
    /// sender that isn't the user. Fuller filtering (newsletters, no-reply,
    /// bulk headers) is item 17.
    func isReplyable(_ message: MailMessage) -> Bool {
        guard let sender = message.from?.email, !sender.isEmpty else { return false }
        let account = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !account.isEmpty, sender.caseInsensitiveCompare(account) == .orderedSame {
            return false
        }
        return true
    }

    /// Records a message as processed and persists the updated set.
    private func markProcessed(_ message: MailMessage, account: String, mailbox: Mailbox) {
        processedMessages.insert(message, account: account, mailbox: mailbox)
        persistence.saveProcessedMessages(processedMessages)
    }

    private func draftMessageIfNeeded(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async {
        guard isReplyable(message),
              !processedMessages.contains(message, account: credentials.email, mailbox: mailbox),
              !hasPendingDraft(for: message, account: credentials.email, mailbox: mailbox) else {
            return
        }

        do {
            if try await draftAndEnqueue(message, mailbox: mailbox) {
                markProcessed(message, account: credentials.email, mailbox: mailbox)
            }
        } catch {
            watchError = Self.draftMessage(for: error)
            logger.error("Watcher draft failed: \(error.localizedDescription)")
        }
    }

    private func seedWatcherBaselineIfNeeded(
        messages: [MailMessage],
        account: String,
        mailbox: Mailbox
    ) -> Bool {
        guard !processedMessages.hasBaseline(account: account, mailbox: mailbox) else { return false }
        for message in messages {
            processedMessages.insert(message, account: account, mailbox: mailbox)
        }
        processedMessages.insertBaseline(account: account, mailbox: mailbox)
        persistence.saveProcessedMessages(processedMessages)
        logger.info("Inbox watcher baseline seeded with \(messages.count) messages")
        return true
    }

    private func hasPendingDraft(for message: MailMessage, account: String, mailbox: Mailbox) -> Bool {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mailbox = mailbox.imapName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return pendingDrafts.contains { draft in
            guard draft.sourceAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == account,
                  draft.sourceMailbox?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == mailbox else {
                return false
            }
            let matchesMessageID = draft.sourceMessageID.map { sourceMessageID in
                guard let messageID = message.messageID else { return false }
                return !sourceMessageID.isEmpty && sourceMessageID == messageID
            } ?? false
            let matchesUID = draft.sourceUIDValidity == message.uidValidity && draft.id == message.id
            return matchesMessageID || matchesUID
        }
    }
}
