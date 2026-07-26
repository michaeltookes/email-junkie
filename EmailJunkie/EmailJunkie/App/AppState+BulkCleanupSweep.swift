import EmailJunkieMail
import Foundation

/// Thrown to unwind a sweep that was superseded (a newer action or a cancel),
/// so the caller returns quietly without reporting completion or an error.
private struct SweepSuperseded: Error {}

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

    /// How many consecutive transient failures (e.g. a rate-limit "try again
    /// later") to ride out before giving up and reporting partial progress.
    static let bulkSweepMaxTransientRetries = 5

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

        do {
            let total = try await sweepUntilClear(context)
            guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
            bulk.completionMessage = Self.bulkCompletionMessage(
                for: MailBulkResult(action: action, affectedCount: total)
            )
            await runMailboxSearch()
        } catch is SweepSuperseded {
            return
        } catch {
            guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
            bulk.error = Self.sweepErrorMessage(error, movedSoFar: bulk.sweepMovedSoFar ?? 0)
            await runMailboxSearch()
        }
    }

    /// Loops preview+apply, pacing between passes and riding out transient
    /// rate-limit failures, until the filter is exhausted or a pass makes no
    /// progress. Returns the total moved; throws on a non-transient error or
    /// after too many consecutive transient failures.
    private func sweepUntilClear(_ context: SweepContext) async throws -> Int {
        var total = 0
        var transientFailures = 0
        for _ in 0..<Self.bulkSweepMaxPasses {
            let moved: Int?
            do {
                moved = try await runOneSweepPass(context)
            } catch {
                guard try await shouldRetryAfterTransientFailure(error, &transientFailures, context) else {
                    throw error
                }
                continue
            }
            transientFailures = 0
            guard let moved else { throw SweepSuperseded() }
            guard moved > 0 else { break }
            total += moved
            bulk.sweepMovedSoFar = total
            // Breathe between passes so a rapid burst of full scans does not trip
            // the provider's rate limit.
            try? await Task.sleep(nanoseconds: bulkSweepPacingNanoseconds)
        }
        return total
    }

    /// Whether a failed pass should be retried: only transient failures, only
    /// while still current, and only up to the retry ceiling. Backs off (longer
    /// each time) before returning `true`.
    private func shouldRetryAfterTransientFailure(
        _ error: Error,
        _ transientFailures: inout Int,
        _ context: SweepContext
    ) async throws -> Bool {
        transientFailures += 1
        guard Self.isTransientBulkError(error),
              transientFailures <= Self.bulkSweepMaxTransientRetries,
              isCurrentBulkCleanupApply(context.generation, account: context.account) else {
            return false
        }
        try? await Task.sleep(nanoseconds: bulkSweepPacingNanoseconds &* UInt64(transientFailures))
        return true
    }

    /// A rate limit or a temporary server hiccup is retryable; a rejected
    /// command (e.g. no MOVE support) is not.
    static func isTransientBulkError(_ error: Error) -> Bool {
        guard case MailError.commandFailed(let text) = error else { return false }
        let lowered = text.lowercased()
        return ["try again", "server error", "temporar", "timeout", "too many", "busy", "unavailable"]
            .contains { lowered.contains($0) }
    }

    /// Error text that preserves partial progress: a sweep that moved thousands
    /// before being throttled should say so and invite another run, not read as
    /// a total failure.
    static func sweepErrorMessage(_ error: Error, movedSoFar: Int) -> String {
        let base = message(for: error)
        guard movedSoFar > 0 else { return base }
        let noun = movedSoFar == 1 ? "message" : "messages"
        return "Moved \(movedSoFar) \(noun) before the server asked us to slow down. "
            + "Wait a moment and run it again to continue. (\(base))"
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
