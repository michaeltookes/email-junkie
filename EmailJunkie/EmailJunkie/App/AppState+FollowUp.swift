import EmailJunkieMail
import Foundation

/// Post-call follow-up actions on `AppState` (item 51): ingest a transcript,
/// draft a follow-up in the user's voice, and route it through the existing
/// approval → send/save pipeline as an *authored* draft (no source message).
extension AppState {

    /// Whether a follow-up can be drafted right now (mail + AI connected),
    /// mirroring `canGenerateDraft`.
    var canCreateFollowUp: Bool {
        isLLMConnected && mailCredentials.isComplete
    }

    /// Drafts a follow-up from an ingested transcript and enqueues it for review.
    /// Recipients are optional here — they are editable in review before approval
    /// (auto-fill is item 52's job) — so the watched-folder path can enqueue with
    /// none and the composer can pre-fill them. Returns the enqueued draft.
    @discardableResult
    func createFollowUp(
        from ingested: IngestedTranscript,
        recipients: [MailAddress] = [],
        subject: String? = nil
    ) async throws -> Draft {
        guard let llmConfiguration = currentDraftLLMConfiguration else {
            throw DraftError.llmUnavailable
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            throw DraftDispatchError.missingCredentials
        }
        let parsed = ingested.parsed()
        guard !parsed.isEmpty else { throw DraftError.emptyDraft }

        let body = try await makeFollowUpBody(parsed: parsed, llmConfiguration: llmConfiguration)
        guard mailCredentials == credentials,
              currentDraftLLMConfiguration == llmConfiguration else {
            throw DraftDispatchError.accountChanged
        }
        let draft = makeAuthoredDraft(
            body: body,
            recipients: Self.dedupedRecipients(recipients),
            subject: Self.followUpSubject(subject, suggestedTitle: ingested.suggestedTitle),
            model: llmConfiguration.model,
            credentials: credentials
        )
        try enqueuePendingDraft(draft)
        return draft
    }

    /// Applies edited recipients to a queued authored follow-up (item 51) and
    /// persists them, so the review card's recipient list is what actually
    /// dispatches and survives relaunch. Returns the updated draft, the unchanged
    /// draft when identical, or `nil` if it could not be applied durably.
    @discardableResult
    func updatePendingDraftRecipients(_ draft: Draft, to recipients: [MailAddress]) -> Draft? {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else { return nil }
        guard pendingDrafts[index].isAuthored else { return pendingDrafts[index] }
        guard pendingDrafts[index].offlineQueuedDispatch == nil,
              offlineQueuedDispatch[draft.identity] == nil,
              !isWaitingForNetwork(draft.identity) else {
            return pendingDrafts[index]
        }
        let deduped = Self.dedupedRecipients(recipients)
        guard pendingDrafts[index].authoredRecipients != deduped else { return pendingDrafts[index] }

        let previous = pendingDrafts[index]
        pendingDrafts[index].authoredRecipients = deduped
        pendingDrafts[index].sourceFrom = deduped.first
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts[index] = previous
            approvalError = Self.draftMessage(for: error)
            return nil
        }
        notifier.refreshNotification(for: pendingDrafts[index], sendBehavior: sendBehavior)
        return pendingDrafts[index]
    }

    // MARK: - Helpers

    private func makeFollowUpBody(
        parsed: ParsedTranscript,
        llmConfiguration: DraftLLMConfiguration
    ) async throws -> String {
        let profile = voiceProfile
        return try await FollowUpGenerator().makeFollowUp(
            transcript: parsed,
            voiceProfile: profile,
            model: llmConfiguration.model
        ) { [llm] request in
            try await llm.complete(
                request,
                provider: llmConfiguration.provider,
                apiKey: llmConfiguration.apiKey,
                baseURL: llmConfiguration.baseURL
            )
        }
    }

    private func makeAuthoredDraft(
        body: String,
        recipients: [MailAddress],
        subject: String,
        model: String,
        credentials: MailAccountCredentials
    ) -> Draft {
        Draft(
            id: uniqueAuthoredDraftID(),
            sourceUIDValidity: nil,
            sourceAccountEmail: credentials.email,
            sourceMailHost: credentials.host,
            sourceMailPort: credentials.port,
            sourceMailbox: nil,
            sourceSubject: subject,
            // Mirror the first recipient into sourceFrom so the review card and
            // notification can show a name; recipients drive actual dispatch.
            sourceFrom: recipients.first,
            sourceReplyTo: nil,
            sourceMessageID: nil,
            replySubject: subject,
            body: body,
            model: model,
            generatedAt: Date(),
            authoredRecipients: recipients
        )
    }

    /// A synthetic id that doesn't collide with any queued draft. Authored drafts
    /// have no IMAP UID, so their `identity` is `account|?|?|id` — uniqueness of
    /// `id` among pending drafts is enough to keep it distinct.
    private func uniqueAuthoredDraftID() -> UInt32 {
        let existing = Set(pendingDrafts.map(\.id))
        var candidate = UInt32.random(in: 1...UInt32.max)
        while existing.contains(candidate) {
            candidate = UInt32.random(in: 1...UInt32.max)
        }
        return candidate
    }

    static func followUpSubject(_ provided: String?, suggestedTitle: String?) -> String {
        if let provided = provided?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty {
            return provided
        }
        if let title = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "Follow-up: \(title)"
        }
        return "Post-call follow-up"
    }

    /// Parses a free-form recipients string (comma/semicolon/newline separated,
    /// tolerating `Name <email>` and space-separated addresses) into unique,
    /// syntactically plausible addresses.
    static func parseRecipients(_ text: String) -> [MailAddress] {
        var addresses: [MailAddress] = []
        for entry in text.components(separatedBy: CharacterSet(charactersIn: ",;\n")) {
            addresses.append(contentsOf: emailsInEntry(entry).map { MailAddress(email: $0) })
        }
        return dedupedRecipients(addresses)
    }

    static func dedupedRecipients(_ recipients: [MailAddress]) -> [MailAddress] {
        var seen = Set<String>()
        return recipients.filter { seen.insert($0.email.lowercased()).inserted }
    }

    private static func emailsInEntry(_ entry: String) -> [String] {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        if let start = trimmed.lastIndex(of: "<"), let end = trimmed.lastIndex(of: ">"), start < end {
            let inner = String(trimmed[trimmed.index(after: start)..<end])
            return isLikelyEmail(inner) ? [inner] : []
        }
        return trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter(isLikelyEmail)
    }

    static func isLikelyEmail(_ token: String) -> Bool {
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}
