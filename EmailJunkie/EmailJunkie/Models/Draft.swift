import EmailJunkieMail
import Foundation

/// A generated reply draft, associated with the message it replies to so it can
/// be threaded and sent correctly later (items 9 & 12).
struct Draft: Codable, Identifiable, Equatable {
    /// The source message's IMAP UID (stable within its mailbox).
    var id: UInt32
    /// UIDVALIDITY captured with the source UID, for safe re-fetch before send.
    var sourceUIDValidity: UInt32?
    /// The account that produced this draft, when created by the watcher.
    var sourceAccountEmail: String?
    /// The mailbox that contained the source message, when created by the watcher.
    var sourceMailbox: String?
    /// The source message's subject.
    var sourceSubject: String
    /// The source message's sender.
    var sourceFrom: MailAddress?
    /// The address replies should be sent to, when the source specified one.
    var sourceReplyTo: MailAddress?
    /// The source message's RFC 5322 `Message-ID`, for reply threading.
    var sourceMessageID: String?
    /// The reply subject (`Re: …`).
    var replySubject: String
    /// The generated reply body.
    var body: String
    /// The model that produced the draft.
    var model: String
    /// When the draft was generated.
    var generatedAt: Date

    init(
        id: UInt32,
        sourceUIDValidity: UInt32?,
        sourceAccountEmail: String? = nil,
        sourceMailbox: String? = nil,
        sourceSubject: String,
        sourceFrom: MailAddress?,
        sourceReplyTo: MailAddress?,
        sourceMessageID: String?,
        replySubject: String,
        body: String,
        model: String,
        generatedAt: Date
    ) {
        self.id = id
        self.sourceUIDValidity = sourceUIDValidity
        self.sourceAccountEmail = sourceAccountEmail
        self.sourceMailbox = sourceMailbox
        self.sourceSubject = sourceSubject
        self.sourceFrom = sourceFrom
        self.sourceReplyTo = sourceReplyTo
        self.sourceMessageID = sourceMessageID
        self.replySubject = replySubject
        self.body = body
        self.model = model
        self.generatedAt = generatedAt
    }
}
