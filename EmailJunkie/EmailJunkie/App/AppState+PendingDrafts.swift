import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "PendingDrafts")

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
    func approveDraft(_ draft: Draft, sendBehavior approvalSendBehavior: SendBehavior? = nil) async {
        guard pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return }
        guard !approvingDraftIDs.contains(draft.identity) else { return }

        approvalError = nil
        let credentials = mailCredentials
        guard credentials.isComplete else {
            approvalError = "Connect an email account first."
            return
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            approvalError = "This draft was generated for a different email account."
            return
        }

        approvingDraftIDs.insert(draft.identity)
        defer { approvingDraftIDs.remove(draft.identity) }

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

    /// Denies (discards) a pending draft without sending or saving it.
    func denyDraft(_ draft: Draft) {
        guard !approvingDraftIDs.contains(draft.identity) else { return }
        approvalError = nil
        do {
            try removePendingDraft(draft)
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

    func draftMatchesCurrentAccount(_ draft: Draft, credentials: MailAccountCredentials) -> Bool {
        guard let sourceAccount = draft.sourceAccountEmail else { return false }
        return normalizedEmail(sourceAccount) == normalizedEmail(credentials.email)
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
