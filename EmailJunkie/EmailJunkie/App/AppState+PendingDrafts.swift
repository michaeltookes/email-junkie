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
    /// send-behavior setting, then removes it from the queue on success.
    func approveDraft(_ draft: Draft) async {
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
            let removalIndex = try removePendingDraft(draft, removeNotification: false)
            do {
                switch sendBehavior {
                case .autoSend:
                    try await performSend(draft, credentials: credentials)
                case .saveAsDraft:
                    try await performSave(draft, credentials: credentials)
                }
                notifier.removeNotification(identity: draft.identity)
            } catch {
                restorePendingDraft(draft, at: removalIndex)
                throw error
            }
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
    func handleNotificationAction(_ action: DraftNotificationAction, identity: String) {
        switch action {
        case .open:
            openReviewHandler?()
        case .approve:
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else { return }
            Task { await approveDraft(draft) }
        case .deny:
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else { return }
            denyDraft(draft)
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

    private func restorePendingDraft(_ draft: Draft, at index: Int?) {
        guard !pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return }
        let insertionIndex = min(index ?? pendingDrafts.count, pendingDrafts.count)
        pendingDrafts.insert(draft, at: insertionIndex)
        pendingDraftCount = pendingDrafts.count

        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            logger.error("Failed to restore pending draft after approval error: \(error.localizedDescription)")
        }
    }

    private func draftMatchesCurrentAccount(_ draft: Draft, credentials: MailAccountCredentials) -> Bool {
        guard let sourceAccount = draft.sourceAccountEmail else { return false }
        return normalizedEmail(sourceAccount) == normalizedEmail(credentials.email)
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
