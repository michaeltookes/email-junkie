import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "PendingDrafts")

private enum RegenerationReplacementError: LocalizedError {
    case alreadyApproved

    var errorDescription: String? {
        "That replacement draft was already approved. The original draft is still queued for review."
    }
}

/// Approval-queue actions on `AppState`: approve (send/save per the send-behavior
/// setting) or deny (discard) a watcher-produced draft, plus routing of the
/// native-notification actions. Kept separate so `AppState` stays within limits.
extension AppState {

    /// What "Approve" will do for the current send-behavior setting, as a short
    /// label for the review UI (also satisfies item 9's approval indicator).
    var approveActionLabel: String {
        sendBehavior == .autoSend ? "Send" : "Save to Drafts"
    }

    /// Approves a pending draft: sends it or saves it as a Gmail draft per the
    /// supplied send behavior (defaulting to the current setting), then removes
    /// it from the queue on success.
    ///
    /// Unless `force` is set, the draft's thread is re-checked first (item 12);
    /// if it changed, the send is blocked and a `pendingStaleWarnings` entry is
    /// raised so the review card can warn with send-anyway / regenerate / discard.
    /// Passing `force: true` is the user's "send anyway" override.
    func approveDraft(
        _ draft: Draft,
        sendBehavior approvalSendBehavior: SendBehavior? = nil,
        force: Bool = false
    ) async {
        guard pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return }
        guard !approvingDraftIDs.contains(draft.identity) else { return }

        approvalError = nil
        // A flagged draft needs the user's input first — never send or save it,
        // even via a notification "Approve" action in auto-send mode (item 13).
        guard !draft.isFlagged else {
            approvalError = Self.draftMessage(for: DraftError.needsUserInput)
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            approvalError = "Connect an email account first."
            return
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            approvalError = "This draft was generated for a different email account."
            return
        }
        guard draftSourceAllowsReplyDispatch(draft) else {
            approvalError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return
        }

        approvingDraftIDs.insert(draft.identity)
        defer { approvingDraftIDs.remove(draft.identity) }

        if !force, case .stale(let reason) = await threadStalenessVerdict(for: draft, credentials: credentials) {
            recordPendingStaleWarning(reason, for: draft)
            return
        }
        pendingStaleWarnings.removeValue(forKey: draft.identity)

        do {
            switch approvalSendBehavior ?? sendBehavior {
            case .autoSend:
                try await performSend(draft, credentials: credentials)
            case .saveAsDraft:
                try await performSave(draft, credentials: credentials)
            }
            try finalizeApprovedDraft(draft)
        } catch {
            approvalError = Self.draftMessage(for: error)
        }
    }

    private func recordPendingStaleWarning(_ reason: StaleThreadReason, for draft: Draft) {
        pendingStaleWarnings[draft.identity] = reason
    }

    /// Denies (discards) a pending draft without sending or saving it.
    func denyDraft(_ draft: Draft) {
        guard !approvingDraftIDs.contains(draft.identity) else { return }
        approvalError = nil
        pendingStaleWarnings.removeValue(forKey: draft.identity)
        do {
            try removePendingDraft(draft)
        } catch {
            approvalError = Self.draftMessage(for: error)
        }
    }

    /// Re-drafts a stale queued reply against the newest related source-thread
    /// message (item 12's "regenerate" option). The old draft remains queued until
    /// the replacement is successfully generated and persisted.
    func regeneratePendingDraft(_ draft: Draft) async {
        guard pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return }
        guard !approvingDraftIDs.contains(draft.identity) else { return }
        guard let mailbox = Self.sourceMailbox(for: draft), mailbox.supportsReplyDrafting else {
            approvalError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            approvalError = "Connect an email account first."
            return
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            approvalError = "This draft was generated for a different email account."
            return
        }

        approvalError = nil
        approvingDraftIDs.insert(draft.identity)
        defer { approvingDraftIDs.remove(draft.identity) }

        do {
            let message = try await regenerationSource(for: draft, mailbox: mailbox, credentials: credentials)
            guard var replacement = try await makePendingDraft(
                for: message,
                mailbox: mailbox,
                requireWatching: false
            ) else {
                approvalError = "The draft could not be regenerated because account settings changed."
                return
            }
            replacement.generatedAt = draft.generatedAt
            let replacementWarning = await threadStalenessVerdict(
                for: replacement,
                credentials: credentials
            ).reason
            try replacePendingDraft(draft, with: replacement, staleReason: replacementWarning)
        } catch {
            approvalError = Self.draftMessage(for: error)
        }
    }

    /// Routes a native-notification action back into the queue.
    func handleNotificationAction(_ action: DraftNotificationAction, identity: String) async {
        switch action {
        case .open:
            openReviewHandler?()
        case .approve(let sendBehavior):
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else { return }
            await approveDraft(draft, sendBehavior: sendBehavior)
            if pendingStaleWarnings[identity] != nil {
                openReviewHandler?()
            }
        case .deny:
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else { return }
            denyDraft(draft)
        }
    }

    private func finalizeApprovedDraft(_ draft: Draft) throws {
        do {
            try recordApprovedDraftIdentity(draft.identity)
            removePendingDraftAfterApproval(draft)
        } catch {
            logger.error("Failed to persist approved draft tombstone: \(error.localizedDescription)")
            try removePendingDraft(draft, removeNotification: false)
        }
        notifier.removeNotification(identity: draft.identity)
    }

    private func recordApprovedDraftIdentity(_ identity: String) throws {
        var approvedDrafts = persistence.loadApprovedDraftIdentities()
        approvedDrafts.insert(identity)
        try persistence.saveApprovedDraftIdentitiesSync(approvedDrafts)
    }

    private func removePendingDraftAfterApproval(_ draft: Draft) {
        guard pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return }
        pendingDrafts.removeAll { $0.identity == draft.identity }
        pendingDraftCount = pendingDrafts.count

        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            logger.error("Failed to clean approved draft; tombstone will suppress reload: \(error.localizedDescription)")
        }
    }

    /// Removes a draft from the queue only after the updated queue is durable.
    @discardableResult
    private func removePendingDraft(_ draft: Draft, removeNotification: Bool = true) throws -> Int? {
        let previousDrafts = pendingDrafts
        guard let removalIndex = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else { return nil }
        pendingDrafts.removeAll { $0.identity == draft.identity }
        pendingDraftCount = pendingDrafts.count

        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts = previousDrafts
            pendingDraftCount = previousDrafts.count
            logger.error("Failed to persist pending drafts after removal: \(error.localizedDescription)")
            throw error
        }
        if removeNotification {
            notifier.removeNotification(identity: draft.identity)
        }
        return removalIndex
    }

    private func regenerationSource(
        for draft: Draft,
        mailbox: Mailbox,
        credentials: MailAccountCredentials
    ) async throws -> MailMessage {
        let subject = StaleThreadCheck.searchSubject(for: draft.sourceSubject)
        let thread = try await sourceThreadInspectionResult(
            credentials,
            mailbox: mailbox,
            subject: subject,
            draft: draft
        )
        guard let source = StaleThreadCheck.regenerationSource(
            draft: draft,
            threadMessages: thread.messages
        ) else {
            throw DraftError.sourceMessageUnavailable
        }
        return source
    }

    private func replacePendingDraft(
        _ draft: Draft,
        with replacement: Draft,
        staleReason: StaleThreadReason?
    ) throws {
        let previousDrafts = pendingDrafts
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else { return }
        if replacement.identity != draft.identity, isReplacementDraftUnavailable(replacement) {
            throw RegenerationReplacementError.alreadyApproved
        }
        pendingDrafts.removeAll {
            $0.identity == draft.identity || $0.identity == replacement.identity
        }
        pendingDrafts.insert(replacement, at: min(index, pendingDrafts.count))
        pendingDraftCount = pendingDrafts.count

        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts = previousDrafts
            pendingDraftCount = previousDrafts.count
            logger.error("Failed to persist regenerated draft: \(error.localizedDescription)")
            throw error
        }

        pendingStaleWarnings.removeValue(forKey: draft.identity)
        pendingStaleWarnings.removeValue(forKey: replacement.identity)
        if let staleReason {
            pendingStaleWarnings[replacement.identity] = staleReason
        }
        notifier.removeNotification(identity: draft.identity)
        if replacement.identity != draft.identity {
            notifier.removeNotification(identity: replacement.identity)
        }
        notifier.notify(for: replacement, sendBehavior: sendBehavior)
    }

    private func isReplacementDraftUnavailable(_ replacement: Draft) -> Bool {
        approvingDraftIDs.contains(replacement.identity)
            || persistence.loadApprovedDraftIdentities().contains(replacement.identity)
    }

    func draftMatchesCurrentAccount(_ draft: Draft, credentials: MailAccountCredentials) -> Bool {
        guard let sourceAccount = draft.sourceAccountEmail else { return false }
        return normalizedEmail(sourceAccount) == normalizedEmail(credentials.email)
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
