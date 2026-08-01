import EmailJunkieMail
import Foundation

/// Why an approved draft's target thread is no longer in the state it was when
/// the draft was generated — a stale-send risk the app blocks before dispatch
/// (item 12). A stale send is especially embarrassing in auto-send mode, where
/// it goes out silently.
enum StaleThreadReason: String, Equatable, Codable, CaseIterable {
    /// The source message is no longer in the mailbox it was drafted from —
    /// archived, deleted, or moved.
    case sourceMissing
    /// A newer message has arrived in the same thread since the draft was made.
    case newerReplyInThread
    /// A message from the user is already in this thread since the draft was
    /// generated — they appear to have replied by hand.
    case alreadyReplied

    /// A short headline for the warning UI.
    var headline: String {
        switch self {
        case .sourceMissing: return "The original message is gone"
        case .newerReplyInThread: return "A newer reply arrived"
        case .alreadyReplied: return "You may have already replied"
        }
    }

    /// A one-line explanation shown under the headline.
    var detail: String {
        switch self {
        case .sourceMissing:
            return "The message this reply answers was archived, deleted, or moved. "
                + "Sending now could reply into a conversation that has already been handled."
        case .newerReplyInThread:
            return "Someone added to this thread after the draft was written, so the reply may not account for what they said."
        case .alreadyReplied:
            return "A message from you is already in this thread since the draft was written. Sending again could duplicate your reply."
        }
    }
}

/// The result of re-checking a draft's thread just before dispatch.
enum StaleThreadVerdict: Equatable {
    /// The thread is unchanged — safe to send.
    case fresh
    /// The thread changed; carries why so the UI can warn precisely.
    case stale(StaleThreadReason)

    var reason: StaleThreadReason? {
        if case .stale(let reason) = self { return reason }
        return nil
    }

    var isStale: Bool { reason != nil }
}

/// Pure stale-thread evaluation, isolated from IMAP so the detection rules can be
/// exhaustively unit-tested against representative thread-change cases (item 12).
///
/// The inputs are re-fetched envelope-level views of the thread: source-mailbox
/// candidates and post-generation Sent candidates, including exact header-search
/// supplements when a known thread chain spans subject edits. Ordering within a
/// mailbox is by UID, which increases monotonically, so a related message with a
/// UID higher than the source arrived after it.
enum StaleThreadCheck {

    /// Reply/forward prefixes stripped when reducing a subject to a thread key.
    private static let replyPrefixes = ["re:", "fwd:", "fw:"]

    /// Normalizes a subject to a thread key: strips any run of leading reply /
    /// forward prefixes and lowercases, so "Re: Fwd: Hi" and "hi" match.
    static func normalizedSubjectKey(_ subject: String) -> String {
        var trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            let lowered = trimmed.lowercased()
            guard let prefix = replyPrefixes.first(where: { lowered.hasPrefix($0) }) else { break }
            trimmed = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed.lowercased()
    }

    /// The substring handed to IMAP `SUBJECT` search: the base subject without
    /// reply prefixes, so both "X" and "Re: X" match the same thread.
    static func searchSubject(for subject: String) -> String {
        normalizedSubjectKey(subject)
    }

    /// Evaluates freshness from re-fetched thread state.
    ///
    /// - Parameters:
    ///   - draft: the reply about to be dispatched.
    ///   - threadMessages: source mailbox candidates for the draft's thread.
    ///   - threadTruncated: whether that search had more pages — when true, the
    ///     source's absence from this page is inconclusive, so "source missing"
    ///     is not claimed.
    ///   - sentReplies: Sent candidates since the draft was made.
    static func verdict(
        draft: Draft,
        threadMessages: [MailMessage],
        threadTruncated: Bool,
        sentReplies: [MailMessage]
    ) -> StaleThreadVerdict {
        let sourcePresent = threadMessages.contains { isSourceMessage($0, draft: draft) }

        // The source is gone — only trust this when the whole thread was seen.
        if !sourcePresent && !threadTruncated {
            return .stale(.sourceMissing)
        }

        let thread = relatedThreadMessages(draft: draft, threadMessages: threadMessages)

        // The user already replied by hand since the draft was generated.
        let threadMessageIDs = relatedThreadMessageIDs(draft: draft, threadMessages: thread)
        let sent = sentReplies.filter {
            isRelatedSentReply($0, draft: draft, relatedThreadMessageIDs: threadMessageIDs)
        }
        if !sent.isEmpty {
            return .stale(.alreadyReplied)
        }

        // A related message with a higher UID than the source arrived after it.
        if thread.contains(where: { isNewerThanSource($0, draft: draft) }) {
            return .stale(.newerReplyInThread)
        }

        return .fresh
    }

    /// Picks the message a regeneration should answer. When a newer related reply
    /// is available, this returns that message rather than the stale source UID.
    static func regenerationSource(
        draft: Draft,
        threadMessages: [MailMessage],
        requireUIDComparable: Bool = true
    ) -> MailMessage? {
        relatedThreadMessages(draft: draft, threadMessages: threadMessages)
            .filter { isIncomingRegenerationCandidate($0, draft: draft) }
            .filter { !requireUIDComparable || isUIDComparable($0, draft: draft) }
            .max { $0.id < $1.id }
    }

    static func messageIDSearchValue(_ value: String?) -> String? {
        normalizedMessageID(value)
    }

    static func relatedMessageIDSearchValues(draft: Draft, threadMessages: [MailMessage]) -> Set<String> {
        let thread = relatedThreadMessages(draft: draft, threadMessages: threadMessages)
        return relatedThreadMessageIDs(draft: draft, threadMessages: thread)
    }

    private static func relatedThreadMessages(draft: Draft, threadMessages: [MailMessage]) -> [MailMessage] {
        let linkage = linkedThreadLinkage(draft: draft, candidateMessages: threadMessages)
        return threadMessages.filter {
            linkage.relatedUIDs.contains($0.id)
                || (hasSameThreadSubject($0, draft: draft)
                    && canUseParticipantFallback($0, relatedThreadMessageIDs: linkage.relatedMessageIDs)
                    && sharesParticipant($0, draft: draft, includeRecipients: false))
        }
    }

    private static func linkedThreadLinkage(
        draft: Draft,
        candidateMessages: [MailMessage]
    ) -> (relatedUIDs: Set<UInt32>, relatedMessageIDs: Set<String>) {
        var relatedUIDs = Set<UInt32>()
        var relatedMessageIDs = Set<String>()
        if let sourceMessageID = normalizedMessageID(draft.sourceMessageID) {
            relatedMessageIDs.insert(sourceMessageID)
        }

        var changed = true
        while changed {
            changed = false
            for message in candidateMessages where !relatedUIDs.contains(message.id) {
                if isSourceMessage(message, draft: draft)
                    || sharesThreadMessageID(message, relatedMessageIDs: relatedMessageIDs) {
                    relatedUIDs.insert(message.id)
                    insertThreadMessageIDs(from: message, into: &relatedMessageIDs)
                    changed = true
                }
            }
        }
        return (relatedUIDs, relatedMessageIDs)
    }

    private static func isRelatedSentReply(
        _ message: MailMessage,
        draft: Draft,
        relatedThreadMessageIDs: Set<String>
    ) -> Bool {
        if isDirectReplyToSource(message, draft: draft) { return true }
        if let inReplyTo = normalizedMessageID(message.inReplyTo),
           relatedThreadMessageIDs.contains(inReplyTo) {
            return true
        }

        guard hasSameThreadSubject(message, draft: draft) else { return false }
        let sourceAddresses = sourceParticipantAddresses(for: draft)
        guard !sourceAddresses.isEmpty else { return false }
        guard canUseParticipantFallback(message, relatedThreadMessageIDs: relatedThreadMessageIDs) else { return false }
        let sentRecipients = Set(message.to.compactMap { normalizedEmail($0.email) })
        return !sentRecipients.isDisjoint(with: sourceAddresses)
    }

    private static func isIncomingRegenerationCandidate(_ message: MailMessage, draft: Draft) -> Bool {
        guard let accountEmail = draft.sourceAccountEmail.flatMap(normalizedEmail),
              let fromEmail = message.from?.email,
              let normalizedFrom = normalizedEmail(fromEmail) else {
            return true
        }
        return normalizedFrom != accountEmail
    }

    private static func isSourceMessage(_ message: MailMessage, draft: Draft) -> Bool {
        message.id == draft.id && isUIDComparable(message, draft: draft)
    }

    private static func isNewerThanSource(_ message: MailMessage, draft: Draft) -> Bool {
        isUIDComparable(message, draft: draft) && message.id > draft.id
    }

    private static func isUIDComparable(_ message: MailMessage, draft: Draft) -> Bool {
        guard let draftUIDValidity = draft.sourceUIDValidity,
              let messageUIDValidity = message.uidValidity else {
            return true
        }
        return draftUIDValidity == messageUIDValidity
    }

    private static func hasSameThreadSubject(_ message: MailMessage, draft: Draft) -> Bool {
        normalizedSubjectKey(message.subject) == normalizedSubjectKey(draft.sourceSubject)
    }

    private static func isDirectReplyToSource(_ message: MailMessage, draft: Draft) -> Bool {
        matchesMessageID(message.inReplyTo, draft.sourceMessageID)
    }

    private static func sharesThreadMessageID(_ message: MailMessage, relatedMessageIDs: Set<String>) -> Bool {
        messageThreadIDs(message).contains { relatedMessageIDs.contains($0) }
    }

    private static func relatedThreadMessageIDs(draft: Draft, threadMessages: [MailMessage]) -> Set<String> {
        var ids = Set<String>()
        if let sourceMessageID = normalizedMessageID(draft.sourceMessageID) {
            ids.insert(sourceMessageID)
        }
        for message in threadMessages {
            insertThreadMessageIDs(from: message, into: &ids)
        }
        return ids
    }

    private static func insertThreadMessageIDs(from message: MailMessage, into ids: inout Set<String>) {
        for id in messageThreadIDs(message) {
            ids.insert(id)
        }
    }

    private static func messageThreadIDs(_ message: MailMessage) -> [String] {
        [message.messageID, message.inReplyTo].compactMap(normalizedMessageID)
    }

    private static func canUseParticipantFallback(
        _ message: MailMessage,
        relatedThreadMessageIDs: Set<String>
    ) -> Bool {
        relatedThreadMessageIDs.isEmpty || messageThreadIDs(message).isEmpty
    }

    private static func sharesParticipant(
        _ message: MailMessage,
        draft: Draft,
        includeRecipients: Bool
    ) -> Bool {
        let sourceAddresses = sourceParticipantAddresses(for: draft)
        guard !sourceAddresses.isEmpty else { return false }

        var messageAddresses = Set<String>()
        if let from = message.from?.email, let normalized = normalizedEmail(from) {
            messageAddresses.insert(normalized)
        }
        if let replyTo = message.replyTo?.email, let normalized = normalizedEmail(replyTo) {
            messageAddresses.insert(normalized)
        }
        if includeRecipients {
            for recipient in message.to {
                if let normalized = normalizedEmail(recipient.email) {
                    messageAddresses.insert(normalized)
                }
            }
        }
        return !messageAddresses.isDisjoint(with: sourceAddresses)
    }

    private static func sourceParticipantAddresses(for draft: Draft) -> Set<String> {
        [
            draft.sourceReplyTo?.email,
            draft.sourceFrom?.email
        ].compactMap { $0.flatMap(normalizedEmail) }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private static func matchesMessageID(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedMessageID(lhs),
              let rhs = normalizedMessageID(rhs) else {
            return false
        }
        return lhs == rhs
    }

    private static func normalizedMessageID(_ value: String?) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count > 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func normalizedEmail(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
