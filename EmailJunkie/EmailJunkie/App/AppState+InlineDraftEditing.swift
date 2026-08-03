import Foundation
import os

private let inlineDraftEditingLogger = Logger(subsystem: "com.tookes.EmailJunkie", category: "PendingDrafts")

extension AppState {

    /// Applies a user's inline edit to a queued draft's reply body (item 19) and
    /// persists it, so the edited text is what later dispatches and the edit
    /// survives a relaunch. Captures the assistant's original body the first time
    /// it diverges (for future voice tuning). Returns the updated draft, the
    /// unchanged draft when the text is identical, or `nil` if the edit could not
    /// be applied durably. On write failure the in-memory edit is rolled back so
    /// memory and disk stay consistent.
    @discardableResult
    func updatePendingDraftBody(_ draft: Draft, to newBody: String) -> Draft? {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else {
            clearPendingDraftBodyEdit(identity: draft.identity)
            return nil
        }
        guard pendingDrafts[index].body != newBody else {
            clearPendingDraftBodyEdit(identity: draft.identity)
            return pendingDrafts[index]
        }

        let previous = pendingDrafts[index]
        pendingDrafts[index].applyEditedBody(newBody)
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts[index] = previous
            pendingDraftUncommittedEditIDs.insert(draft.identity)
            pendingDraftUncommittedEditBodies[draft.identity] = newBody
            inlineDraftEditingLogger.error("Failed to persist edited pending draft: \(error.localizedDescription)")
            approvalError = Self.draftMessage(for: error)
            return nil
        }
        clearPendingDraftBodyEdit(identity: draft.identity)
        notifier.refreshNotification(for: pendingDrafts[index], sendBehavior: sendBehavior)
        return pendingDrafts[index]
    }

    /// Marks whether a pending draft card has editor text that has not yet been
    /// persisted. Notification approvals check this before dispatching.
    func notePendingDraftBodyEdit(_ draft: Draft, editedBody: String) {
        guard let queued = pendingDrafts.first(where: { $0.identity == draft.identity }) else {
            clearPendingDraftBodyEdit(identity: draft.identity)
            return
        }
        if queued.body == editedBody {
            clearPendingDraftBodyEdit(identity: draft.identity)
        } else {
            pendingDraftUncommittedEditIDs.insert(draft.identity)
            pendingDraftUncommittedEditBodies[draft.identity] = editedBody
        }
    }

    /// Persists any inline editor text already registered with the debounce
    /// guard. Used during application termination when SwiftUI may not run
    /// `onDisappear` before the process exits.
    func flushPendingDraftBodyEdits() {
        let edits = pendingDraftUncommittedEditBodies
        for (identity, editedBody) in edits {
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else {
                clearPendingDraftBodyEdit(identity: identity)
                continue
            }
            updatePendingDraftBody(draft, to: editedBody)
        }
    }

    func clearPendingDraftBodyEdit(identity: String) {
        pendingDraftUncommittedEditIDs.remove(identity)
        pendingDraftUncommittedEditBodies.removeValue(forKey: identity)
    }

    /// Applies the current inline editor contents before dispatching. Approval
    /// stops if the edited body cannot be persisted, so the user never sends or
    /// saves a different body from the one shown in the review UI.
    func approvePendingDraft(_ draft: Draft, withEditedBody editedBody: String, force: Bool = false) async {
        guard let updated = updatePendingDraftBody(draft, to: editedBody) else { return }
        await approveDraft(updated, force: force)
    }
}
