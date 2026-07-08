import EmailJunkieMail
import Foundation

/// A generated reply draft, associated with the message it replies to so it can
/// be threaded and sent correctly later (items 9 & 12).
struct Draft: Identifiable, Equatable {
    /// The source message's IMAP UID (stable within its mailbox).
    var id: UInt32
    /// UIDVALIDITY captured with the source UID, for safe re-fetch before send.
    var sourceUIDValidity: UInt32?
    /// The source message's subject.
    var sourceSubject: String
    /// The source message's sender.
    var sourceFrom: MailAddress?
    /// The reply subject (`Re: …`).
    var replySubject: String
    /// The generated reply body.
    var body: String
    /// The model that produced the draft.
    var model: String
    /// When the draft was generated.
    var generatedAt: Date
}
