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
        recordWatcherBaselineStartIfNeeded(account: mailCredentials.email, mailbox: .inbox)
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
        // Outstanding auto-send countdowns (item 23) simply never fire; their
        // drafts stay pending in the queue.
        cancelAllSendCountdowns()
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
            messages = try await fetchWatcherMessages(
                credentials,
                mailbox: mailbox
            )
        } catch {
            watchError = Self.message(for: error)
            logger.error("Inbox poll fetch failed: \(error.localizedDescription)")
            return
        }
        guard watchStatus == .watching, mailCredentials == credentials else { return }
        watchError = nil

        let messagesToProcess = messagesAfterSeedingWatcherBaselineIfNeeded(
            messages: messages,
            account: credentials.email,
            mailbox: mailbox
        )
        if messagesToProcess.isEmpty {
            return
        }

        // Oldest first so enqueued drafts read in chronological order.
        for message in messagesToProcess.reversed() {
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

    /// Records a message as processed and persists the updated set. Internal so
    /// the reply-worthiness gate (item 17) can mark a skipped message handled,
    /// and the override path can mark a force-drafted message handled.
    func markProcessed(_ message: MailMessage, account: String, mailbox: Mailbox) {
        processedMessages.insert(message, account: account, mailbox: mailbox)
        persistence.saveProcessedMessages(processedMessages)
    }

    private func fetchWatcherMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async throws -> [MailMessage] {
        var limit = watchFetchLimit
        var messages = try await mailProvider.fetchRecentMessages(
            credentials,
            mailbox: mailbox,
            limit: limit
        )

        while shouldExpandWatcherFetch(
            messages: messages,
            limit: limit,
            account: credentials.email,
            mailbox: mailbox
        ) {
            let nextLimit = min(limit * 2, watchCatchUpFetchLimit)
            guard nextLimit > limit else { break }
            limit = nextLimit
            messages = try await mailProvider.fetchRecentMessages(
                credentials,
                mailbox: mailbox,
                limit: limit
            )
        }

        return messages
    }

    private func shouldExpandWatcherFetch(
        messages: [MailMessage],
        limit: Int,
        account: String,
        mailbox: Mailbox
    ) -> Bool {
        guard messages.count >= limit, limit < watchCatchUpFetchLimit else { return false }

        if let baselineUID = processedMessages.baselineUID(account: account, mailbox: mailbox),
           Self.isBaselineUIDComparable(messages: messages, baselineUID: baselineUID) {
            return !messages.contains { Self.isMessage($0, atOrBeforeBaselineUID: baselineUID) }
        }

        if let baselineStartDate = processedMessages.baselineStartDate(account: account, mailbox: mailbox) {
            return !messages.contains {
                Self.isMessage($0, beforeBaselineStart: baselineStartDate)
            }
        }

        return false
    }

    private func recordWatcherBaselineStartIfNeeded(account: String, mailbox: Mailbox, date: Date = Date()) {
        guard !processedMessages.hasBaseline(account: account, mailbox: mailbox) else { return }
        guard !processedMessages.hasBaselineStart(account: account, mailbox: mailbox) else { return }
        processedMessages.setBaselineStart(account: account, mailbox: mailbox, date: date)
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
        guard await canDraftAfterSenderRulesAndWorthiness(message, credentials: credentials, mailbox: mailbox) else {
            return
        }
        guard watchStatus == .watching, mailCredentials == credentials else { return }

        do {
            if try await draftAndEnqueue(message, mailbox: mailbox) {
                markProcessed(message, account: credentials.email, mailbox: mailbox)
            }
        } catch {
            watchError = Self.draftMessage(for: error)
            logger.error("Watcher draft failed: \(error.localizedDescription)")
        }
    }

    private func canDraftAfterSenderRulesAndWorthiness(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async -> Bool {
        let skippedReason = skippedMessageReason(message, account: credentials.email, mailbox: mailbox)
        // Sender rules (item 18) layer over the reply-worthiness gate (item 17):
        // an allowlisted sender is force-drafted regardless of the heuristics; a
        // blocklisted sender is skipped with a visible reason. Only when the rules
        // have no opinion does the worthiness gate run. Precedence and the
        // allow-vs-block tie-break live in the pure `SenderRules` evaluator.
        switch senderRuleDecision(for: message) {
        case .block:
            guard watchStatus == .watching, mailCredentials == credentials else { return false }
            recordSkip(message, reason: .senderBlocklisted, account: credentials.email, mailbox: mailbox)
            return false
        case .forceDraft:
            removeSkippedMessage(message, account: credentials.email, mailbox: mailbox)
            return true
        case .noOpinion:
            if let skippedReason {
                guard skippedReason == .senderBlocklisted else { return false }
                removeSkippedMessage(message, account: credentials.email, mailbox: mailbox)
            }
            // Reply-worthiness gate (item 17): skip obvious non-replyable mail
            // before the costly LLM draft call. A skip is recorded in memory but
            // not marked durably processed, so a false skip can be recovered after
            // log loss or app restart.
            if let reason = await replyWorthinessSkipReason(message, credentials: credentials, mailbox: mailbox) {
                guard watchStatus == .watching, mailCredentials == credentials else { return false }
                recordSkip(message, reason: reason, account: credentials.email, mailbox: mailbox)
                return false
            }
            return true
        }
    }

    private func messagesAfterSeedingWatcherBaselineIfNeeded(
        messages: [MailMessage],
        account: String,
        mailbox: Mailbox
    ) -> [MailMessage] {
        let hasBaseline = processedMessages.hasBaseline(account: account, mailbox: mailbox)
        let baselineStartDate = processedMessages.baselineStartDate(account: account, mailbox: mailbox)
        let baselineUID = processedMessages.baselineUID(account: account, mailbox: mailbox)

        if hasBaseline {
            return messages.filter {
                Self.isMessage(
                    $0,
                    afterBaselineUID: baselineUID,
                    onOrAfterBaselineStart: baselineStartDate
                )
            }
        }

        let messagesToProcess: [MailMessage]
        let baselineMessages: [MailMessage]
        if let baselineUID {
            messagesToProcess = messages.filter { Self.isMessage($0, afterBaselineUID: baselineUID) }
            baselineMessages = messages.filter { Self.isMessage($0, atOrBeforeBaselineUID: baselineUID) }
        } else if let baselineStartDate {
            messagesToProcess = messages.filter {
                Self.isMessage($0, onOrAfterInitialBaselineStart: baselineStartDate)
            }
            baselineMessages = messages.filter {
                !Self.isMessage($0, onOrAfterInitialBaselineStart: baselineStartDate)
            }
        } else {
            messagesToProcess = []
            baselineMessages = messages
        }

        if baselineUID == nil, let historicalCutoff = baselineMessages.max(by: { $0.id < $1.id }) {
            processedMessages.setBaselineUID(
                account: account,
                mailbox: mailbox,
                uid: historicalCutoff.id,
                uidValidity: historicalCutoff.uidValidity
            )
        }

        for message in baselineMessages {
            processedMessages.insert(message, account: account, mailbox: mailbox)
        }
        processedMessages.insertBaseline(account: account, mailbox: mailbox)
        persistence.saveProcessedMessages(processedMessages)
        logger.info("Inbox watcher baseline seeded: \(baselineMessages.count) historical, \(messagesToProcess.count) post-start eligible")
        return baselineStartDate == nil ? [] : messagesToProcess
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

    private static func isMessage(
        _ message: MailMessage,
        afterBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff?,
        onOrAfterBaselineStart startDate: Date?
    ) -> Bool {
        guard let baselineUID else {
            return isMessage(message, onOrAfterBaselineStart: startDate)
        }
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else {
            return isMessage(message, onOrAfterBaselineStart: startDate)
        }
        return isMessage(message, afterBaselineUID: baselineUID)
    }

    private static func isBaselineUIDComparable(
        messages: [MailMessage],
        baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard let baselineUIDValidity = baselineUID.uidValidity else { return true }
        return !messages.contains {
            guard let messageUIDValidity = $0.uidValidity else { return false }
            return messageUIDValidity != baselineUIDValidity
        }
    }

    private static func isMessage(
        _ message: MailMessage,
        afterBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else { return true }
        return message.id > baselineUID.uid
    }

    private static func isMessage(
        _ message: MailMessage,
        atOrBeforeBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else { return false }
        return message.id <= baselineUID.uid
    }

    private static func isMessageUIDComparable(
        _ message: MailMessage,
        baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard let baselineUIDValidity = baselineUID.uidValidity,
              let messageUIDValidity = message.uidValidity else {
            return true
        }
        return messageUIDValidity == baselineUIDValidity
    }

    private static func isMessage(_ message: MailMessage, onOrAfterBaselineStart startDate: Date?) -> Bool {
        guard let startDate else { return true }
        if let date = parsedMessageDate(message.date) {
            return date >= startDate
        }
        return true
    }

    private static func isMessage(_ message: MailMessage, onOrAfterInitialBaselineStart startDate: Date) -> Bool {
        guard let date = parsedMessageDate(message.date) else { return false }
        return date >= startDate
    }

    private static func isMessage(_ message: MailMessage, beforeBaselineStart startDate: Date) -> Bool {
        guard let date = parsedMessageDate(message.date) else { return false }
        return date < startDate
    }

    static func parsedMessageDate(_ value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for candidate in rfc5322DateCandidates(value) {
            for format in [
                "EEE, d MMM yyyy HH:mm:ss Z",
                "d MMM yyyy HH:mm:ss Z",
                "EEE, d MMM yyyy HH:mm Z",
                "d MMM yyyy HH:mm Z"
            ] {
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) {
                    return date
                }
            }
        }
        return nil
    }

    private static func rfc5322DateCandidates(_ value: String) -> [String] {
        let withoutComments = strippedRFC5322Comments(from: value)
        guard withoutComments != value else { return [value] }
        return [value, withoutComments]
    }

    private static func strippedRFC5322Comments(from value: String) -> String {
        var output = ""
        var commentDepth = 0
        var isEscapingCommentCharacter = false

        for character in value {
            if commentDepth > 0 {
                if isEscapingCommentCharacter {
                    isEscapingCommentCharacter = false
                } else if character == "\\" {
                    isEscapingCommentCharacter = true
                } else if character == "(" {
                    commentDepth += 1
                } else if character == ")" {
                    commentDepth -= 1
                }
                continue
            }

            if character == "(" {
                commentDepth = 1
            } else {
                output.append(character)
            }
        }

        return output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
