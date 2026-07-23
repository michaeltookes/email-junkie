import EmailJunkieMail
import Foundation

/// State for the bulk-cleanup panel (item 42): the chosen action, the preview of
/// what it would affect, and progress while it runs.
///
/// `previewQuery` is the safety anchor. The user approves a *specific* preview,
/// so the apply step replays that query rather than reading the live search
/// controls — otherwise editing a filter after previewing would silently change
/// what gets deleted.
struct BulkCleanupState: Equatable {
    var action: MailBulkAction = .markRead
    var preview: MailBulkPreview?
    /// The query `preview` was produced from; apply uses exactly this.
    var previewQuery: MailboxBrowserQuery?
    var isPreviewing = false
    var isApplying = false
    var progress: MailBulkProgress?
    var error: String?
    var completionMessage: String?

    /// Whether a confirmed apply is currently allowed.
    var canApply: Bool {
        guard let preview, previewQuery != nil else { return false }
        return preview.matchCount > 0 && !isPreviewing && !isApplying
    }

    /// Clears everything derived from a previous run.
    mutating func reset() {
        preview = nil
        previewQuery = nil
        progress = nil
        error = nil
        completionMessage = nil
    }
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
        let query = browser.query
        bulk.reset()

        let credentials = mailCredentials
        guard credentials.isComplete else {
            bulk.error = "Connect an account first."
            return
        }

        bulk.isPreviewing = true
        defer { bulk.isPreviewing = false }

        do {
            let preview = try await mailProvider.previewBulkCleanup(
                credentials,
                mailbox: query.mailbox,
                criteria: query.criteria,
                sampleLimit: Self.bulkPreviewSampleSize,
                selectionCap: Self.bulkSelectionCap
            )
            bulk.preview = preview
            bulk.previewQuery = query
        } catch {
            bulk.error = Self.message(for: error)
        }
    }

    /// Applies the selected action to everything the *previewed* query matched.
    ///
    /// Refuses to run if the search inputs changed since the preview: the user
    /// approved a specific set of messages, so a changed filter must be
    /// re-previewed rather than silently acted on.
    func applyBulkCleanup() async {
        guard let previewQuery = bulk.previewQuery, let preview = bulk.preview else {
            bulk.error = "Preview the cleanup before running it."
            return
        }
        guard previewQuery == browser.query else {
            bulk.reset()
            bulk.error = "The search changed since the preview. Preview again before running cleanup."
            return
        }
        guard preview.matchCount > 0 else {
            bulk.error = "Nothing matches that filter."
            return
        }

        let credentials = mailCredentials
        guard credentials.isComplete else {
            bulk.error = "Connect an account first."
            return
        }

        let action = bulk.action
        bulk.error = nil
        bulk.completionMessage = nil
        bulk.isApplying = true
        bulk.progress = MailBulkProgress(processed: 0, total: preview.matchCount)
        defer { bulk.isApplying = false }

        do {
            let result = try await mailProvider.applyBulkCleanup(
                credentials,
                mailbox: previewQuery.mailbox,
                criteria: previewQuery.criteria,
                action: action,
                selectionCap: Self.bulkSelectionCap,
                onProgress: nil
            )
            bulk.progress = MailBulkProgress(
                processed: result.affectedCount,
                total: result.affectedCount
            )
            bulk.completionMessage = Self.bulkCompletionMessage(for: result)
            // The affected messages have moved or changed state, so the visible
            // result set is stale — reload it rather than showing phantom rows.
            bulk.preview = nil
            bulk.previewQuery = nil
            await runMailboxSearch()
        } catch {
            bulk.error = Self.message(for: error)
        }
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
}
