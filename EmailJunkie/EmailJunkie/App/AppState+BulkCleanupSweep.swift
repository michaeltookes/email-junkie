import EmailJunkieMail
import Foundation

/// The fixed inputs of a multi-pass sweep, threaded through each pass so the
/// per-pass helper stays small (item 49).
private struct SweepContext {
    var query: MailboxBrowserQuery
    var action: MailBulkAction
    var criteria: MailSearchCriteria
    var credentials: MailAccountCredentials
    var account: BulkCleanupAccountIdentity
    var generation: Int
}

/// The verify-until-stable bulk sweep (item 49): repeatedly clean a filter
/// until the mailbox stops revealing older matches. Split out of
/// `AppState+BulkCleanup` to keep both files within length limits.
extension AppState {

    /// Ceiling on sweep passes, a safety backstop against an unexpected
    /// non-terminating loop. At up to `bulkSelectionCap` moved per pass this
    /// covers far more mail than any real mailbox holds.
    static let bulkSweepMaxPasses = 200

    /// Repeatedly previews and applies a move action until the filter reports no
    /// remaining matches or a pass makes no progress.
    ///
    /// att.net/Yahoo exposes only ~10,000 messages over IMAP at once, so a single
    /// pass can only reach the matches inside that window; removing them slides
    /// older mail into view, which the next pass then reaches. Looping until the
    /// count reaches zero is the only way "clean all" actually cleans all on such
    /// a mailbox (item 49). Only meaningful for actions that *remove* messages —
    /// marking read leaves the window unchanged, so callers route that to the
    /// single-pass path instead.
    func applyBulkCleanupSweep() async {
        let query = browser.query
        let action = bulk.action
        let credentials = mailCredentials
        guard credentials.isComplete else {
            bulk.error = "Connect an account first."
            return
        }
        guard action.destination != nil else {
            // No source-shrinking effect, so a sweep cannot make progress past
            // the visibility cap; a single pass is the honest behavior.
            await applyBulkCleanup()
            return
        }
        guard let criteria = Self.bulkCleanupCriteria(for: query.criteria, action: action) else {
            bulk.error = "Nothing matches that filter."
            return
        }

        let requestGeneration = nextBulkGeneration()
        let account = BulkCleanupAccountIdentity(credentials: credentials)
        let context = SweepContext(
            query: query, action: action, criteria: criteria,
            credentials: credentials, account: account, generation: requestGeneration
        )
        bulk.reset()
        bulk.isApplying = true
        bulk.sweepMovedSoFar = 0
        defer {
            if bulkGeneration == requestGeneration {
                bulk.isApplying = false
                bulk.sweepMovedSoFar = nil
            }
        }

        var totalMoved = 0
        do {
            for _ in 0..<Self.bulkSweepMaxPasses {
                let moved = try await runOneSweepPass(context)
                guard let moved, moved > 0 else { break }
                totalMoved += moved
                bulk.sweepMovedSoFar = totalMoved
            }
            guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
            bulk.completionMessage = Self.bulkCompletionMessage(
                for: MailBulkResult(action: action, affectedCount: totalMoved)
            )
            await runMailboxSearch()
        } catch {
            guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
            bulk.error = Self.message(for: error)
        }
    }

    /// One preview+apply pass of a sweep. Returns the number moved, `0` when the
    /// filter is exhausted (stop), or `nil` when the request was superseded (a
    /// newer action or a cancel) so the caller must abandon quietly.
    private func runOneSweepPass(_ context: SweepContext) async throws -> Int? {
        guard isCurrentBulkCleanupApply(context.generation, account: context.account) else { return nil }
        let preview = try await mailProvider.previewBulkCleanup(
            context.credentials,
            mailbox: context.query.mailbox,
            criteria: context.criteria,
            sampleLimit: 0,
            selectionCap: Self.bulkSelectionCap
        )
        guard isCurrentBulkCleanupApply(context.generation, account: context.account) else { return nil }
        guard preview.matchCount > 0, let selection = preview.selection else { return 0 }

        let result = try await mailProvider.applyBulkCleanup(
            context.credentials,
            mailbox: context.query.mailbox,
            criteria: context.criteria,
            action: context.action,
            selection: selection,
            selectionCap: Self.bulkSelectionCap,
            onProgress: nil
        )
        guard isCurrentBulkCleanupApply(context.generation, account: context.account) else { return nil }
        return result.affectedCount
    }

    /// Stops an in-flight sweep or apply after the current pass by superseding
    /// its generation, so its later stages no-op.
    func cancelBulkCleanup() {
        _ = nextBulkGeneration()
        bulk.isApplying = false
        bulk.isPreviewing = false
        if let moved = bulk.sweepMovedSoFar {
            bulk.completionMessage = "Stopped after moving \(moved) message\(moved == 1 ? "" : "s")."
        }
        bulk.sweepMovedSoFar = nil
        Task { await runMailboxSearch() }
    }
}
