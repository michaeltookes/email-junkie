import EmailJunkieMail
import Foundation

/// A bounded, ordered record of inbox messages the watcher has already handled,
/// so the same message is never drafted twice — even across app restarts.
///
/// Each message is identified by its RFC 5322 `Message-ID` when available (stable
/// and globally unique), falling back to `UIDVALIDITY:UID` (stable within a
/// mailbox) scoped to the current account and mailbox. Oldest keys are evicted
/// first once `limit` is exceeded, so the store stays small while still covering
/// any realistic poll window.
struct ProcessedMessages: Codable, Equatable {

    /// Maximum number of remembered keys before the oldest are evicted.
    static let limit = 1000

    /// Remembered message keys, oldest first.
    private(set) var keys: [String]

    init(keys: [String] = []) {
        self.keys = keys
    }

    enum CodingKeys: String, CodingKey {
        case keys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decodeIfPresent([String].self, forKey: .keys) ?? []
    }

    /// Whether `message` has already been processed.
    func contains(_ message: MailMessage, account: String, mailbox: Mailbox) -> Bool {
        keys.contains(Self.key(for: message, account: account, mailbox: mailbox))
    }

    /// Records `message` as processed, evicting the oldest keys past `limit`.
    /// No-op if already present (its position is left unchanged).
    mutating func insert(_ message: MailMessage, account: String, mailbox: Mailbox) {
        let key = Self.key(for: message, account: account, mailbox: mailbox)
        guard !keys.contains(key) else { return }
        keys.append(key)
        if keys.count > Self.limit {
            keys.removeFirst(keys.count - Self.limit)
        }
    }

    /// A stable identity for a message: its Message-ID when present, else a
    /// scoped `UIDVALIDITY:UID` composite (stable within one account/mailbox).
    static func key(for message: MailMessage, account: String, mailbox: Mailbox) -> String {
        if let messageID = message.messageID, !messageID.isEmpty {
            return "mid:\(messageID)"
        }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mailbox = mailbox.imapName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let validity = message.uidValidity.map(String.init) ?? "?"
        return "uid:acct=\(account)|mailbox=\(mailbox)|validity=\(validity)|uid=\(message.id)"
    }
}
