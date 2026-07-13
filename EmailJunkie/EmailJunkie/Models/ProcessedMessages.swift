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
    /// Account/mailbox scopes that have had their initial watcher baseline seeded.
    private(set) var baselines: [String]

    init(keys: [String] = [], baselines: [String] = []) {
        self.keys = keys
        self.baselines = baselines
    }

    enum CodingKeys: String, CodingKey {
        case keys
        case baselines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decodeIfPresent([String].self, forKey: .keys) ?? []
        baselines = try container.decodeIfPresent([String].self, forKey: .baselines) ?? []
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

    /// Whether the watcher has seeded the current-inbox baseline for this scope.
    func hasBaseline(account: String, mailbox: Mailbox) -> Bool {
        baselines.contains(Self.baselineKey(account: account, mailbox: mailbox))
    }

    /// Records that the watcher has seeded the current-inbox baseline for this scope.
    mutating func insertBaseline(account: String, mailbox: Mailbox) {
        let key = Self.baselineKey(account: account, mailbox: mailbox)
        guard !baselines.contains(key) else { return }
        baselines.append(key)
    }

    /// A stable identity for a message: its Message-ID when present, else a
    /// scoped `UIDVALIDITY:UID` composite (stable within one account/mailbox).
    static func key(for message: MailMessage, account: String, mailbox: Mailbox) -> String {
        if let messageID = message.messageID, !messageID.isEmpty {
            return "mid:\(messageID)"
        }
        let validity = message.uidValidity.map(String.init) ?? "?"
        return "uid:\(scopeKey(account: account, mailbox: mailbox))|validity=\(validity)|uid=\(message.id)"
    }

    static func baselineKey(account: String, mailbox: Mailbox) -> String {
        "baseline:\(scopeKey(account: account, mailbox: mailbox))"
    }

    private static func scopeKey(account: String, mailbox: Mailbox) -> String {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mailbox = mailbox.imapName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "acct=\(account)|mailbox=\(mailbox)"
    }
}
