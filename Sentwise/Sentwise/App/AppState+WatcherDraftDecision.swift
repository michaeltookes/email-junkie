import SentwiseMail

/// Watcher draft gating that combines sender rules (item 18) with the
/// reply-worthiness check (item 17).
extension AppState {

    func canDraftAfterSenderRulesAndWorthiness(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async -> Bool {
        let skippedReason = skippedMessageReason(message, account: credentials.email, mailbox: mailbox)
        // Sender rules layer over the reply-worthiness gate: an allowlisted sender
        // is force-drafted regardless of heuristics; a blocklisted sender is
        // skipped with a visible reason. Only a no-opinion verdict falls through.
        switch senderRuleDecision(for: message) {
        case .block:
            guard skippedReason != .senderBlocklisted else { return false }
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
            if let reason = await replyWorthinessSkipReason(message, credentials: credentials, mailbox: mailbox) {
                guard watchStatus == .watching, mailCredentials == credentials else { return false }
                recordSkip(message, reason: reason, account: credentials.email, mailbox: mailbox)
                return false
            }
            return true
        }
    }
}
