import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "SendCountdown")

/// Auto-send safety net (item 23): a short, cancellable grace period between the
/// user approving an auto-send draft and the actual SMTP dispatch. The draft is
/// left in the pending queue for the whole window, so a quit or crash mid-window
/// leaves it pending — never lost, never sent. The stale-thread re-check (item 12)
/// runs at the END of the window, immediately before the send, so a thread that
/// moved on during the countdown is still caught. Kept in its own file so
/// `AppState+PendingDrafts` stays within lint limits.
extension AppState {

    /// The remaining seconds on an in-progress send countdown for `identity`, or
    /// `nil` when that draft is not counting down. Drives the review UI.
    func sendCountdownRemaining(for identity: String) -> Int? {
        pendingSendCountdowns[identity]
    }

    /// Runs the stale-thread re-check (unless forced) and then sends or saves the
    /// draft, finalizing it on success. Shared by the immediate-approval path and
    /// the end of the auto-send countdown, so both re-check freshness at dispatch
    /// time and record the same activity/tombstone bookkeeping.
    func dispatchApprovedDraft(
        _ draft: Draft,
        sendBehavior effectiveSendBehavior: SendBehavior,
        force: Bool,
        credentials: MailAccountCredentials
    ) async throws {
        var dispatchCredentials = credentials
        if !force {
            let freshness = try await currentFreshnessCheck(for: draft, credentials: credentials)
            dispatchCredentials = freshness.credentials
            if let reason = freshness.reason {
                recordPendingStaleWarning(reason, for: draft)
                return
            }
        }
        pendingStaleWarnings.removeValue(forKey: draft.identity)

        switch effectiveSendBehavior {
        case .autoSend:
            try await performSend(draft, credentials: dispatchCredentials)
        case .saveAsDraft:
            try await performSave(draft, credentials: dispatchCredentials)
        }
        try finalizeApprovedDraft(draft)
    }

    /// Starts a cancellable per-draft countdown before an auto-send dispatch. The
    /// draft stays in the pending queue for the whole window (recoverable); only
    /// after the window elapses AND the send succeeds is it removed.
    func startSendCountdown(for draft: Draft, credentials: MailAccountCredentials) {
        let identity = draft.identity
        guard sendCountdownTasks[identity] == nil else { return }
        let seconds = max(sendDelaySeconds, 1)
        pendingSendCountdowns[identity] = seconds
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSendCountdown(for: draft, credentials: credentials, seconds: seconds)
        }
        sendCountdownTasks[identity] = task
    }

    private func runSendCountdown(
        for draft: Draft,
        credentials: MailAccountCredentials,
        seconds: Int
    ) async {
        let identity = draft.identity
        var remaining = seconds
        while remaining > 0 {
            do {
                try await Task.sleep(nanoseconds: sendCountdownTickNanoseconds)
            } catch {
                return // Cancelled — the canceller owns state cleanup.
            }
            if Task.isCancelled { return }
            remaining -= 1
            // Only reflect the tick while this is still the active countdown.
            guard pendingSendCountdowns[identity] != nil else { return }
            pendingSendCountdowns[identity] = remaining
        }
        if Task.isCancelled { return }
        await fireSendCountdown(for: draft, credentials: credentials)
    }

    /// Fires at the end of the window: dispatches the (possibly edited) draft after
    /// re-checking staleness. On a stale verdict the send is blocked and the
    /// existing stale-warning flow surfaces instead; the draft stays pending.
    private func fireSendCountdown(for draft: Draft, credentials: MailAccountCredentials) async {
        let identity = draft.identity
        pendingSendCountdowns.removeValue(forKey: identity)
        sendCountdownTasks.removeValue(forKey: identity)

        // The draft may have been denied/removed during the window.
        guard let current = pendingDrafts.first(where: { $0.identity == identity }) else { return }
        // Never double-dispatch if an approval is already in flight for it.
        guard !approvingDraftIDs.contains(identity) else { return }

        approvingDraftIDs.insert(identity)
        defer { approvingDraftIDs.remove(identity) }
        do {
            // `current` carries any inline edit (item 19) made during the window.
            try await dispatchApprovedDraft(
                current,
                sendBehavior: .autoSend,
                force: false,
                credentials: credentials
            )
        } catch {
            approvalError = Self.draftMessage(for: error)
            logger.error("Auto-send after countdown failed: \(error.localizedDescription)")
        }
    }

    /// User-initiated cancel during the window (item 23): stops the countdown and
    /// leaves the draft in the pending queue untouched, with any inline edits
    /// (item 19) preserved. Records a `.sendCanceled` activity entry.
    func cancelSendCountdown(_ draft: Draft) {
        let identity = draft.identity
        guard let task = sendCountdownTasks.removeValue(forKey: identity) else { return }
        task.cancel()
        pendingSendCountdowns.removeValue(forKey: identity)
        approvalError = nil
        recordDraftActivity(.sendCanceled, for: draft)
    }

    /// Cancels every outstanding countdown without recording an activity entry.
    /// Used when the account switches, watching stops, or the app terminates — the
    /// pending drafts remain queued and simply never auto-fire.
    func cancelAllSendCountdowns() {
        guard !sendCountdownTasks.isEmpty else { return }
        for task in sendCountdownTasks.values {
            task.cancel()
        }
        sendCountdownTasks.removeAll()
        pendingSendCountdowns.removeAll()
    }
}
