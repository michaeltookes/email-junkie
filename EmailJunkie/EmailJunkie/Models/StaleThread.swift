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
            return "The message this reply answers was archived, deleted, or moved. Sending now could reply into a conversation that has already been handled."
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
/// The inputs are re-fetched envelope-level views of the thread: the source
/// mailbox's subject-search results and the Sent mailbox's subject-search
/// results since the draft was generated. Ordering within a mailbox is by UID,
/// which increases monotonically, so a message with a UID higher than the source
/// arrived after it — the signal used for "a newer reply arrived" without having
/// to parse the raw envelope date strings.
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
    ///   - threadMessages: subject-search results from the source mailbox.
    ///   - threadTruncated: whether that search had more pages — when true, the
    ///     source's absence from this page is inconclusive, so "source missing"
    ///     is not claimed.
    ///   - sentReplies: subject-search results from Sent since the draft was made.
    static func verdict(
        draft: Draft,
        threadMessages: [MailMessage],
        threadTruncated: Bool,
        sentReplies: [MailMessage]
    ) -> StaleThreadVerdict {
        let key = normalizedSubjectKey(draft.sourceSubject)
        let thread = threadMessages.filter { normalizedSubjectKey($0.subject) == key }
        let sourcePresent = thread.contains { $0.id == draft.id }

        // The source is gone — only trust this when the whole thread was seen.
        if !sourcePresent && !threadTruncated {
            return .stale(.sourceMissing)
        }

        // The user already replied by hand since the draft was generated.
        let sent = sentReplies.filter { normalizedSubjectKey($0.subject) == key }
        if !sent.isEmpty {
            return .stale(.alreadyReplied)
        }

        // A message with a higher UID than the source arrived after it.
        if thread.contains(where: { $0.id > draft.id }) {
            return .stale(.newerReplyInThread)
        }

        return .fresh
    }
}
