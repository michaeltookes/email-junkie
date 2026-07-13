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
    /// generate a draft and enqueue it. Marks a message processed as soon as it
    /// is selected for drafting so it is never drafted twice (transient-failure
    /// retry is a later resilience item). Reentrancy-guarded.
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
        let messages: [MailMessage]
        do {
            messages = try await mailProvider.fetchRecentMessages(
                credentials,
                mailbox: .inbox,
                limit: watchFetchLimit
            )
        } catch {
            watchError = Self.message(for: error)
            logger.error("Inbox poll fetch failed: \(error.localizedDescription)")
            return
        }
        watchError = nil

        // Oldest first so enqueued drafts read in chronological order.
        for message in messages.reversed() {
            guard watchStatus == .watching, mailCredentials == credentials else { break }
            guard isReplyable(message), !processedMessages.contains(message) else { continue }

            markProcessed(message)
            do {
                try await draftAndEnqueue(message)
            } catch {
                watchError = Self.draftMessage(for: error)
                logger.error("Watcher draft failed: \(error.localizedDescription)")
            }
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
    private func markProcessed(_ message: MailMessage) {
        processedMessages.insert(message)
        persistence.saveProcessedMessages(processedMessages)
    }
}
