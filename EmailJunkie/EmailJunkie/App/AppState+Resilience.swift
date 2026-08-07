import EmailJunkieMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "Resilience")

/// Offline queue, reachability handling, and the shared retry wrappers for
/// item 27. The queue deliberately *reuses* the pending-draft store: an approved
/// draft that can't dispatch while offline simply stays pending (as it already
/// does until a send succeeds, per item 23) with a "waiting for network" flag,
/// and re-dispatches on reconnect through the normal approval path — so the
/// no-duplicate-send guards (`approvingDraftIDs`, the approved tombstone) all
/// still apply, and restart survival comes for free from the persisted queue.
extension AppState {

    // MARK: - Reachability lifecycle

    /// Begins reachability monitoring. Called by the app at launch (not in
    /// `init`) so tests never spin up a real `NWPathMonitor`.
    func startReachabilityMonitoring() {
        reachability.start()
        isOnline = reachability.isOnline
    }

    /// Stops reachability monitoring (app teardown).
    func stopReachabilityMonitoring() {
        reachability.stop()
    }

    /// Reacts to a reachability change: while offline the poll loop skips (see
    /// `pollInboxOnce`); on reconnect it polls immediately and drains any drafts
    /// that were queued while offline.
    func handleReachabilityChange(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        guard online else {
            logger.info("Network offline — pausing polls and queueing dispatches")
            return
        }
        logger.info("Network online — resuming polls and draining offline queue")
        recordActivity(ActivityEvent(kind: .resumedOnline, account: normalizedConnectedAccountEmail))
        if watchStatus == .watching {
            inboxWatcher.pollNow()
        }
        Task { await resumeQueuedDraftsAfterReconnect() }
    }

    // MARK: - Offline queue (reuses the pending-draft store)

    /// Whether a pending draft is deferred waiting for the network to return.
    func isWaitingForNetwork(_ identity: String) -> Bool {
        draftsWaitingForNetwork.contains(identity)
    }

    static func offlineQueuedDispatches(from drafts: [Draft]) -> [String: OfflineQueuedDraftDispatch] {
        var dispatches: [String: OfflineQueuedDraftDispatch] = [:]
        for draft in drafts {
            guard let intent = draft.offlineQueuedDispatch else { continue }
            dispatches[draft.identity] = intent
        }
        return dispatches
    }

    /// Defers an approved draft because we're offline: it stays pending, gains a
    /// "waiting for network" flag, and will dispatch on reconnect with the same
    /// send behavior. No send is attempted, so there's no risk of a partial send.
    func queueDraftForNetwork(
        _ draft: Draft,
        sendBehavior behavior: SendBehavior,
        force: Bool = false
    ) throws {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else { return }
        let intent = OfflineQueuedDraftDispatch(sendBehavior: behavior, force: force)
        let previous = pendingDrafts[index]
        pendingDrafts[index].offlineQueuedDispatch = intent
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts[index] = previous
            logger.error("Failed to persist offline dispatch intent: \(error.localizedDescription)")
            throw error
        }
        offlineQueuedDispatch[draft.identity] = intent
        draftsWaitingForNetwork.insert(draft.identity)
        recordDraftActivity(.queuedOffline, for: pendingDrafts[index])
        logger.info("Queued draft for network (\(behavior.rawValue, privacy: .public), force: \(force, privacy: .public))")
    }

    /// Clears a single draft's offline-queue state (on deny, dispatch, or drain).
    func clearOfflineQueueEntry(_ identity: String) {
        offlineQueuedDispatch.removeValue(forKey: identity)
        draftsWaitingForNetwork.remove(identity)
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == identity }),
              pendingDrafts[index].offlineQueuedDispatch != nil else {
            return
        }
        pendingDrafts[index].offlineQueuedDispatch = nil
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            logger.error("Failed to clear offline dispatch intent: \(error.localizedDescription)")
        }
    }

    /// Clears every offline-queue entry (account switch, disconnect). The drafts
    /// themselves remain pending; they simply won't auto-dispatch.
    func clearAllOfflineQueueEntries() {
        guard !offlineQueuedDispatch.isEmpty || !draftsWaitingForNetwork.isEmpty else { return }
        offlineQueuedDispatch.removeAll()
        draftsWaitingForNetwork.removeAll()
        var didClearPersistedIntent = false
        for index in pendingDrafts.indices where pendingDrafts[index].offlineQueuedDispatch != nil {
            pendingDrafts[index].offlineQueuedDispatch = nil
            didClearPersistedIntent = true
        }
        guard didClearPersistedIntent else { return }
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            logger.error("Failed to clear offline dispatch intents: \(error.localizedDescription)")
        }
    }

    /// Re-dispatches every offline-queued draft through the normal approval path
    /// on reconnect. If the network is still flapping, `approveDraft` re-queues it,
    /// so this is self-correcting; a draft denied while offline is simply skipped.
    func resumeQueuedDraftsAfterReconnect() async {
        guard !offlineQueuedDispatch.isEmpty else { return }
        // Snapshot: approveDraft may re-queue entries, mutating the map mid-drain.
        let queued = offlineQueuedDispatch
        for (identity, intent) in queued {
            clearOfflineQueueEntry(identity)
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else { continue }
            await approveDraft(draft, sendBehavior: intent.sendBehavior, force: intent.force)
        }
    }

    func shouldQueueDispatchAfterOfflineFailure(_ error: Error) -> Bool {
        !isOnline && ResilienceClassifier.classify(error) == .transient
    }

    func dispatchApprovedDraftOrQueueOnOfflineFailure(
        _ draft: Draft,
        sendBehavior effectiveSendBehavior: SendBehavior,
        force: Bool,
        credentials: MailAccountCredentials
    ) async throws {
        do {
            try await dispatchApprovedDraft(
                draft,
                sendBehavior: effectiveSendBehavior,
                force: force,
                credentials: credentials
            )
        } catch {
            guard shouldQueueDispatchAfterOfflineFailure(error) else { throw error }
            try queueDraftForNetwork(draft, sendBehavior: effectiveSendBehavior, force: force)
        }
    }

    // MARK: - Retry wrappers

    /// Runs a mail/LLM operation under the shared backoff policy, retrying only
    /// on transient failures. `sendInterruptedAfterSubmission`, auth failures, and
    /// permanent errors are never retried, so this can never cause a duplicate
    /// send: the SMTP layer only reports a pre-DATA drop as retryable.
    func withResilientRetry<T>(_ operation: () async throws -> T) async throws -> T {
        try await retryRunner.run(
            classify: ResilienceClassifier.retryDecision(for:),
            operation: operation
        )
    }

    /// Records exactly one failure activity for a dispatch error, its kind
    /// reflecting the cause: an auth failure (never retried) surfaces as
    /// `.authFailed`; a transient failure that survived every retry surfaces as
    /// `.retryExhausted`; a permanent or ambiguous-send failure surfaces as the
    /// caller's `failureKind` (`.sendFailed`/`.saveFailed`), whose detail carries
    /// the "may have been sent" note for the ambiguous case. Returns the
    /// classification so callers can react (e.g. pause watching).
    @discardableResult
    func recordDispatchFailureActivity(
        _ error: Error,
        for draft: Draft,
        failureKind: ActivityEventKind
    ) -> FailureClass {
        let classification = ResilienceClassifier.classify(error)
        let kind: ActivityEventKind
        switch classification {
        case .authentication:
            kind = .authFailed
        case .transient:
            kind = .retryExhausted
        case .ambiguousSend, .permanent:
            kind = failureKind
        }
        recordDraftActivity(kind, for: draft, detail: Self.draftMessage(for: error))
        return classification
    }

    /// The connected account email for activity linkage, or `nil` when none.
    var normalizedConnectedAccountEmail: String? {
        let email = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }
}
