import Foundation

/// A fetched, readable message body shown in the preview sheet.
struct MailBodyPreview: Identifiable, Equatable {
    /// The source message's IMAP UID.
    let id: UInt32
    let subject: String
    let text: String
}
