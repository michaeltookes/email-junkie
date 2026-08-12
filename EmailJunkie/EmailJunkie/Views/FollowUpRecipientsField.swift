import SwiftUI

/// Editable recipients row for an authored follow-up draft in the review window
/// (item 51). Persists edits to the queued draft so the list that dispatches
/// matches what's shown and survives relaunch. Recipient auto-fill is item 52;
/// until then the user types recipients here before approving.
struct FollowUpRecipientsField: View {
    let draft: Draft
    @EnvironmentObject var appState: AppState
    @State private var text: String
    @State private var persistTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    init(draft: Draft) {
        self.draft = draft
        _text = State(initialValue: (draft.authoredRecipients ?? []).map(\.email).joined(separator: ", "))
    }

    private var isBusy: Bool { appState.approvingDraftIDs.contains(draft.identity) }
    private var isQueuedForNetwork: Bool {
        draft.offlineQueuedDispatch != nil
            || appState.offlineQueuedDispatch[draft.identity] != nil
            || appState.isWaitingForNetwork(draft.identity)
    }
    private var isLocked: Bool { isBusy || isQueuedForNetwork }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("To").font(.caption).bold().foregroundStyle(.secondary)
            TextField("name@example.com, …", text: $text)
                .textFieldStyle(.roundedBorder)
                .disabled(isLocked)
                .focused($isFocused)
                .onSubmit { persistNow() }
                .onChange(of: text) { _, _ in queuePersist() }
                .onChange(of: isFocused) { _, focused in if !focused { persistNow() } }
                .accessibilityLabel("Follow-up recipients")
            if AppState.parseRecipients(text).isEmpty {
                Text("Add at least one recipient to send this follow-up.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear { persistNow() }
    }

    private func queuePersist() {
        guard !isLocked else { return }
        appState.notePendingDraftRecipientEdit(draft, recipients: AppState.parseRecipients(text))
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        guard !isLocked else { return }
        _ = appState.updatePendingDraftRecipients(draft, to: AppState.parseRecipients(text))
    }
}
