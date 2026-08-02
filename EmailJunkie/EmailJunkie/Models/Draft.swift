import EmailJunkieMail
import Foundation

/// Why the assistant couldn't confidently draft a reply — the reply would need
/// information only the user has (item 13). Attached to a `Draft` so the flagged
/// state persists through the pending queue and survives relaunch.
struct DraftNeedsInfo: Codable, Equatable {
    /// One-line explanation of why a confident reply isn't possible.
    var summary: String
    /// Specific things the user would need to supply to complete the reply.
    var missing: [String]

    init(summary: String, missing: [String] = []) {
        self.summary = summary
        self.missing = missing
    }
}

/// A generated reply draft, associated with the message it replies to so it can
/// be threaded and sent correctly later (items 9 & 12).
struct Draft: Codable, Identifiable, Equatable {
    /// The source message's IMAP UID (stable within its mailbox).
    var id: UInt32
    /// UIDVALIDITY captured with the source UID, for safe re-fetch before send.
    var sourceUIDValidity: UInt32?
    /// The account that produced this draft.
    var sourceAccountEmail: String?
    /// The IMAP host that issued the source UID/UIDVALIDITY.
    var sourceMailHost: String?
    /// The IMAP port that issued the source UID/UIDVALIDITY.
    var sourceMailPort: Int?
    /// The mailbox that contained the source message.
    var sourceMailbox: String?
    /// The source message's subject.
    var sourceSubject: String
    /// The source message's sender.
    var sourceFrom: MailAddress?
    /// The address replies should be sent to, when the source specified one.
    var sourceReplyTo: MailAddress?
    /// The source message's RFC 5322 `Message-ID`, for reply threading.
    var sourceMessageID: String?
    /// The readable text of the incoming message, kept so the approval UI can
    /// show it beside the proposed reply. Truncated to bound persistence size.
    var incomingBody: String?
    /// The reply subject (`Re: …`).
    var replySubject: String
    /// The generated reply body. Empty when the draft is flagged as needing the
    /// user's input (`needsInfo` set) — there is no fabricated reply to send.
    var body: String
    /// The model that produced the draft.
    var model: String
    /// When the draft was generated.
    var generatedAt: Date
    /// Set when the assistant declined to fabricate a reply because it needs
    /// information only the user has (item 13). A flagged draft is never sent or
    /// saved until the user resolves it.
    var needsInfo: DraftNeedsInfo?

    /// Whether this draft is flagged as needing the user's input rather than
    /// carrying a ready-to-send reply.
    var isFlagged: Bool { needsInfo != nil }

    init(
        id: UInt32,
        sourceUIDValidity: UInt32?,
        sourceAccountEmail: String? = nil,
        sourceMailHost: String? = nil,
        sourceMailPort: Int? = nil,
        sourceMailbox: String? = nil,
        sourceSubject: String,
        sourceFrom: MailAddress?,
        sourceReplyTo: MailAddress?,
        sourceMessageID: String?,
        incomingBody: String? = nil,
        replySubject: String,
        body: String,
        model: String,
        generatedAt: Date,
        needsInfo: DraftNeedsInfo? = nil
    ) {
        self.id = id
        self.sourceUIDValidity = sourceUIDValidity
        self.sourceAccountEmail = sourceAccountEmail
        self.sourceMailHost = sourceMailHost
        self.sourceMailPort = sourceMailPort
        self.sourceMailbox = sourceMailbox
        self.sourceSubject = sourceSubject
        self.sourceFrom = sourceFrom
        self.sourceReplyTo = sourceReplyTo
        self.sourceMessageID = sourceMessageID
        self.incomingBody = incomingBody
        self.replySubject = replySubject
        self.body = body
        self.model = model
        self.generatedAt = generatedAt
        self.needsInfo = needsInfo
    }

    /// A stable identity across the pending queue and notifications, scoped by
    /// account/mailbox so the same UID in different mailboxes never collides.
    var identity: String {
        let account = sourceAccountEmail ?? "?"
        let mailbox = sourceMailbox ?? "?"
        let validity = sourceUIDValidity.map(String.init) ?? "?"
        return "\(account)|\(mailbox)|\(validity)|\(id)"
    }
}
