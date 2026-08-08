import EmailJunkieMail
import Foundation

/// Sender allow/blocklist wiring on `AppState` (item 18). The watcher consults
/// `senderRuleDecision(for:)` before the reply-worthiness gate; the Settings UI
/// uses the mutation helpers to add and remove rules. The pure matching and
/// precedence live in the `SenderRules` evaluator; this file only holds the live
/// state and persists edits so they take effect on the next poll without restart.
extension AppState {

    /// The rules' verdict for `message`'s sender (its `From` address). Reads the
    /// live published lists, so an edit made in Settings is honored by the very
    /// next poll — no restart needed.
    func senderRuleDecision(for message: MailMessage) -> SenderRuleDecision {
        SenderRules.decide(
            senderEmail: message.from?.email,
            allowlist: senderAllowlist,
            blocklist: senderBlocklist
        )
    }

    /// Adds a sender to the allowlist. Returns `false` when the input can't form a
    /// usable rule (empty / malformed).
    @discardableResult
    func addAllowedSender(_ rawInput: String) -> Bool {
        addSenderRule(rawInput, toAllowlist: true)
    }

    /// Adds a sender to the blocklist. Returns `false` when the input can't form a
    /// usable rule (empty / malformed).
    @discardableResult
    func addBlockedSender(_ rawInput: String) -> Bool {
        addSenderRule(rawInput, toAllowlist: false)
    }

    /// Removes the given allowlist rules and persists the change.
    func removeAllowedSenders(_ rules: [SenderRule]) {
        removeSenderRules(rules, fromAllowlist: true)
    }

    /// Removes the given blocklist rules and persists the change.
    func removeBlockedSenders(_ rules: [SenderRule]) {
        removeSenderRules(rules, fromAllowlist: false)
    }

    /// Removes allowlist rules at the given list offsets (SwiftUI `onDelete`).
    func removeAllowedSenders(atOffsets offsets: IndexSet) {
        removeAllowedSenders(offsets.map { senderAllowlist[$0] })
    }

    /// Removes blocklist rules at the given list offsets (SwiftUI `onDelete`).
    func removeBlockedSenders(atOffsets offsets: IndexSet) {
        removeBlockedSenders(offsets.map { senderBlocklist[$0] })
    }

    private func addSenderRule(_ rawInput: String, toAllowlist: Bool) -> Bool {
        guard let rule = SenderRule(rawInput: rawInput) else { return false }
        // A pattern lives on only one list: adding it to one drops the identical
        // pattern from the other so the lists never contradict at the same key.
        senderAllowlist.removeAll { $0.pattern == rule.pattern }
        senderBlocklist.removeAll { $0.pattern == rule.pattern }
        if toAllowlist {
            senderAllowlist.append(rule)
            senderAllowlist.sort { $0.pattern < $1.pattern }
        } else {
            senderBlocklist.append(rule)
            senderBlocklist.sort { $0.pattern < $1.pattern }
        }
        saveSettings()
        return true
    }

    private func removeSenderRules(_ rules: [SenderRule], fromAllowlist: Bool) {
        guard !rules.isEmpty else { return }
        let patterns = Set(rules.map(\.pattern))
        if fromAllowlist {
            senderAllowlist.removeAll { patterns.contains($0.pattern) }
        } else {
            senderBlocklist.removeAll { patterns.contains($0.pattern) }
        }
        saveSettings()
    }
}
