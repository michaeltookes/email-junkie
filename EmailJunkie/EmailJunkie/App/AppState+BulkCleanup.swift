import EmailJunkieMail
import Foundation

/// State for the bulk-cleanup panel (item 42): the chosen action, the preview of
/// what it would affect, and progress while it runs.
///
/// `previewQuery`, `previewAccount`, and `preview.selection` are the safety
/// anchors. The user approves a *specific* UID set for a *specific* account, so
/// apply does not sweep in mail that matched after preview.
struct BulkCleanupState: Equatable {
    var action: MailBulkAction = .markRead
    var preview: MailBulkPreview?
    /// The query `preview` was produced from; apply must still match it.
    var previewQuery: MailboxBrowserQuery?
    /// The action `preview` was produced for; action-specific eligibility can differ.
    var previewAction: MailBulkAction?
    /// The non-secret account identity `preview` was produced from.
    var previewAccount: BulkCleanupAccountIdentity?
    var isPreviewing = false
    var isApplying = false
    var progress: MailBulkProgress?
    var error: String?
    var completionMessage: String?

    /// Whether a confirmed apply is currently allowed.
    var canApply: Bool {
        guard let preview, previewQuery != nil, previewAction == action, previewAccount != nil else { return false }
        return preview.matchCount > 0 && !isPreviewing && !isApplying
    }

    /// Clears everything derived from a previous run.
    mutating func reset() {
        preview = nil
        previewQuery = nil
        previewAction = nil
        previewAccount = nil
        progress = nil
        error = nil
        completionMessage = nil
    }
}

/// Non-secret account identity used to bind a preview approval to the account
/// that produced it, without retaining app-password material in UI state.
struct BulkCleanupAccountIdentity: Equatable {
    var email: String
    var host: String
    var port: Int

    init(credentials: MailAccountCredentials) {
        email = credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        port = credentials.port
    }
}

private struct BulkCleanupApplyContext {
    var previewQuery: MailboxBrowserQuery
    var criteria: MailSearchCriteria
    var preview: MailBulkPreview
    var previewAccount: BulkCleanupAccountIdentity
    var credentials: MailAccountCredentials
}

/// Bulk-cleanup actions on `AppState` (item 42). Kept in a separate file so
/// `AppState` stays within the file/type length limits.
extension AppState {

    /// How many matches a preview lists for the user to eyeball.
    static let bulkPreviewSampleSize = 25

    /// Ceiling on how many messages a single cleanup pass touches.
    static let bulkSelectionCap = 5_000

    /// Scans the mailbox for what the current filter would affect. Read-only.
    func previewBulkCleanup() async {
        let requestGeneration = nextBulkGeneration()
        let query = browser.query
        let action = bulk.action
        bulk.reset()

        let credentials = mailCredentials
        guard credentials.isComplete else {
            bulk.error = "Connect an account first."
            return
        }
        guard let criteria = Self.bulkCleanupCriteria(for: query.criteria, action: action) else {
            bulk.error = "Mark read only applies to unread messages."
            return
        }

        bulk.isPreviewing = true
        defer {
            if bulkGeneration == requestGeneration {
                bulk.isPreviewing = false
            }
        }

        do {
            let preview = try await mailProvider.previewBulkCleanup(
                credentials,
                mailbox: query.mailbox,
                criteria: criteria,
                sampleLimit: Self.bulkPreviewSampleSize,
                selectionCap: Self.bulkSelectionCap
            )
            guard isCurrentBulkCleanupRequest(requestGeneration, credentials: credentials) else { return }
            bulk.preview = preview
            bulk.previewQuery = query
            bulk.previewAction = action
            bulk.previewAccount = BulkCleanupAccountIdentity(credentials: credentials)
        } catch {
            guard isCurrentBulkCleanupRequest(requestGeneration, credentials: credentials) else { return }
            bulk.error = Self.message(for: error)
        }
    }

    /// Applies the selected action to everything the *previewed* query matched.
    ///
    /// Refuses to run if the search inputs changed since the preview: the user
    /// approved a specific set of messages, so a changed filter must be
    /// re-previewed rather than silently acted on.
    func applyBulkCleanup() async {
        guard let applyContext = validatedBulkApplyContext() else { return }

        let requestGeneration = nextBulkGeneration()
        let action = bulk.action
        bulk.error = nil
        bulk.completionMessage = nil
        bulk.isApplying = true
        bulk.progress = MailBulkProgress(processed: 0, total: applyContext.preview.matchCount)
        defer {
            if bulkGeneration == requestGeneration {
                bulk.isApplying = false
            }
        }

        do {
            let result = try await mailProvider.applyBulkCleanup(
                applyContext.credentials,
                mailbox: applyContext.previewQuery.mailbox,
                criteria: applyContext.criteria,
                action: action,
                selection: applyContext.preview.selection,
                selectionCap: Self.bulkSelectionCap,
                // Batches complete on a NIO event loop, so hop back to the main
                // actor before touching published state.
                onProgress: { [weak self, previewAccount = applyContext.previewAccount] progress in
                    Task { @MainActor in
                        self?.updateBulkApplyProgress(
                            progress,
                            requestGeneration,
                            account: previewAccount
                        )
                    }
                }
            )
            guard isCurrentBulkCleanupApply(requestGeneration, account: applyContext.previewAccount) else { return }
            await finishBulkApply(result)
        } catch {
            guard isCurrentBulkCleanupApply(requestGeneration, account: applyContext.previewAccount) else { return }
            bulk.error = Self.message(for: error)
        }
    }

    func nextBulkGeneration() -> Int {
        bulkGeneration += 1
        return bulkGeneration
    }

    func resetBulkCleanupForAccountChange() {
        _ = nextBulkGeneration()
        bulk.reset()
        bulk.isPreviewing = false
        bulk.isApplying = false
    }

    /// Human-readable summary of a completed run.
    static func bulkCompletionMessage(for result: MailBulkResult) -> String {
        let noun = result.affectedCount == 1 ? "message" : "messages"
        switch result.action {
        case .markRead:
            return "Marked \(result.affectedCount) \(noun) as read."
        case .archive:
            return "Archived \(result.affectedCount) \(noun)."
        case .moveToTrash:
            return "Moved \(result.affectedCount) \(noun) to Trash."
        }
    }

    /// The confirmation question shown before a destructive run.
    static func bulkConfirmationMessage(for action: MailBulkAction, matchCount: Int, isPartial: Bool) -> String {
        let noun = matchCount == 1 ? "message" : "messages"
        let count = isPartial ? "at least \(matchCount)" : "\(matchCount)"
        switch action {
        case .markRead:
            return "Mark \(count) \(noun) as read?"
        case .archive:
            return "Archive \(count) \(noun)? You can find them in the Archive folder."
        case .moveToTrash:
            return "Move \(count) \(noun) to Trash? You can recover them from Trash."
        }
    }

    private func validatedBulkApplyContext() -> BulkCleanupApplyContext? {
        guard let previewQuery = bulk.previewQuery,
              let preview = bulk.preview,
              let previewAction = bulk.previewAction,
              let previewAccount = bulk.previewAccount else {
            bulk.error = "Preview the cleanup before running it."
            return nil
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            bulk.reset()
            bulk.error = "Connect an account first."
            return nil
        }
        guard previewAccount == BulkCleanupAccountIdentity(credentials: credentials) else {
            bulk.reset()
            bulk.error = "The connected account changed since the preview. Preview again before running cleanup."
            return nil
        }
        guard previewQuery == browser.query else {
            bulk.reset()
            bulk.error = "The search changed since the preview. Preview again before running cleanup."
            return nil
        }
        guard previewAction == bulk.action else {
            bulk.reset()
            bulk.error = "The cleanup action changed since the preview. Preview again before running cleanup."
            return nil
        }
        guard let criteria = Self.bulkCleanupCriteria(for: previewQuery.criteria, action: previewAction) else {
            bulk.reset()
            bulk.error = "Mark read only applies to unread messages."
            return nil
        }
        guard preview.matchCount > 0 else {
            bulk.error = "Nothing matches that filter."
            return nil
        }
        guard preview.selection != nil else {
            bulk.reset()
            bulk.error = "Preview the cleanup again before running cleanup."
            return nil
        }
        return BulkCleanupApplyContext(
            previewQuery: previewQuery,
            criteria: criteria,
            preview: preview,
            previewAccount: previewAccount,
            credentials: credentials
        )
    }

    private static func bulkCleanupCriteria(
        for criteria: MailSearchCriteria,
        action: MailBulkAction
    ) -> MailSearchCriteria? {
        guard action == .markRead else { return criteria }
        return criteria.markReadCandidateCriteria()
    }

    private func updateBulkApplyProgress(
        _ progress: MailBulkProgress,
        _ requestGeneration: Int,
        account: BulkCleanupAccountIdentity
    ) {
        guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
        bulk.progress = progress
    }

    private func finishBulkApply(_ result: MailBulkResult) async {
        bulk.progress = MailBulkProgress(
            processed: result.affectedCount,
            total: result.affectedCount
        )
        bulk.completionMessage = Self.bulkCompletionMessage(for: result)
        // The affected messages have moved or changed state, so the visible
        // result set is stale — reload it rather than showing phantom rows.
        bulk.preview = nil
        bulk.previewQuery = nil
        bulk.previewAction = nil
        bulk.previewAccount = nil
        await runMailboxSearch()
    }

    private func isCurrentBulkCleanupRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials
    ) -> Bool {
        bulkGeneration == requestGeneration && mailCredentials == credentials
    }

    private func isCurrentBulkCleanupApply(
        _ requestGeneration: Int,
        account: BulkCleanupAccountIdentity
    ) -> Bool {
        bulkGeneration == requestGeneration
            && BulkCleanupAccountIdentity(credentials: mailCredentials) == account
    }
}
