import SwiftUI

/// The review window for watcher-produced drafts awaiting approval. Lists each
/// pending draft with the incoming message and the proposed reply side by side,
/// and Approve / Deny actions. Approve sends or saves per the send-behavior
/// setting; Deny discards.
struct PendingDraftsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = appState.approvalError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            if appState.pendingDrafts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.pendingDrafts, id: \.identity) { draft in
                            PendingDraftCard(draft: draft)
                                .environmentObject(appState)
                        }
                    }
                    .padding(12)
                }
            }

            if !appState.skippedMessages.isEmpty {
                Divider()
                skippedSection
            }
        }
        .frame(width: 720, height: 520)
    }

    /// A bare-bones list of messages the reply-worthiness gate skipped (item 17),
    /// each with a "Draft anyway" override. The full activity history (item 21)
    /// will replace this; kept minimal deliberately.
    private var skippedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Skipped (\(appState.skippedMessages.count))", systemImage: "nosign")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { appState.dismissAllSkippedMessages() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(appState.skippedMessages) { entry in
                        SkippedMessageRow(entry: entry)
                            .environmentObject(appState)
                    }
                }
            }
            .frame(maxHeight: 132)
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Drafts to review")
                .font(.headline)
            if !appState.pendingDrafts.isEmpty {
                Text("\(appState.pendingDrafts.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
            Spacer()
            Label("Approve will \(appState.approveActionLabel.lowercased())", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No drafts waiting")
                .foregroundStyle(.secondary)
            Text("New replies appear here as the watcher drafts them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One skipped-message row: sender, subject, skip reason, and the override
/// ("Draft anyway") plus a dismiss. Deliberately compact — this is the minimal
/// skip-log surface pending the full activity history (item 21).
private struct SkippedMessageRow: View {
    let entry: SkippedMessage
    @EnvironmentObject var appState: AppState
    @State private var isDrafting = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.senderDisplay)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(entry.reason.headline)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundStyle(.secondary)
                }
                Text(entry.subject.isEmpty ? "(no subject)" : entry.subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isDrafting {
                ProgressView().controlSize(.small)
            } else {
                Button("Draft anyway") {
                    isDrafting = true
                    Task {
                        await appState.forceDraftSkippedMessage(entry)
                        isDrafting = false
                    }
                }
                .font(.caption)
                Button {
                    appState.dismissSkippedMessage(entry)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// A single reviewable draft: incoming message on the left, proposed reply on
/// the right, with Approve / Deny actions.
private struct PendingDraftCard: View {
    let draft: Draft
    @EnvironmentObject var appState: AppState
    @State private var editedBody: String
    @FocusState private var isBodyFocused: Bool

    init(draft: Draft) {
        self.draft = draft
        _editedBody = State(initialValue: draft.body)
    }

    private var isBusy: Bool { appState.approvingDraftIDs.contains(draft.identity) }

    private var staleReason: StaleThreadReason? { appState.pendingStaleWarnings[draft.identity] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.isFlagged {
                Label("Needs your input", systemImage: "exclamationmark.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 12) {
                incomingColumn
                Divider()
                replyColumn
            }
            Divider()
            if let staleReason {
                staleWarning(staleReason)
            } else {
                actions
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(cardStroke, lineWidth: draft.isFlagged ? 1.5 : 1))
    }

    private var cardStroke: Color {
        draft.isFlagged ? Color.orange.opacity(0.5) : Color.secondary.opacity(0.15)
    }

    private var incomingColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Incoming")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            if let sender = draft.sourceFrom {
                Text(sender.name ?? sender.email)
                    .font(.subheadline).bold()
                if sender.name != nil {
                    Text(sender.email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(draft.sourceSubject)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(draft.incomingBody ?? "(message body unavailable)")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var replyColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(draft.isFlagged ? "Can't draft this one" : "Proposed reply")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            if let needsInfo = draft.needsInfo {
                ScrollView {
                    DraftNeedsInfoView(needsInfo: needsInfo)
                }
                .frame(maxHeight: 180)
            } else {
                if let recipient = draft.sourceReplyTo?.email ?? draft.sourceFrom?.email {
                    Text("To: \(recipient)").font(.caption).foregroundStyle(.secondary)
                }
                Text(draft.replySubject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $editedBody)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(maxHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                    .focused($isBodyFocused)
                    .disabled(isBusy)
                    .accessibilityLabel("Reply body")
                    // Persist the inline edit (item 19) when the editor loses
                    // focus, so it survives relaunch even before approval.
                    .onChange(of: isBodyFocused) { _, focused in
                        if !focused {
                            appState.updatePendingDraftBody(draft, to: editedBody)
                        }
                    }
                    // Resync when the underlying draft body changes externally
                    // (e.g. a same-identity regenerate). Typing only changes
                    // `editedBody`, so external draft replacements should win.
                    .onChange(of: draft.body) { _, newValue in
                        editedBody = newValue
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(draft.isFlagged ? "Dismiss" : "Deny", role: .destructive) {
                appState.denyDraft(draft)
            }
            .disabled(isBusy)

            // A flagged draft can't be approved — there is nothing safe to send.
            if !draft.isFlagged {
                Button(appState.approveActionLabel) {
                    Task { await appState.approvePendingDraft(draft, withEditedBody: editedBody) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
            }
        }
    }

    /// The conflict warning shown when a draft's thread changed since it was
    /// generated (item 12), offering send-anyway / regenerate / discard.
    private func staleWarning(_ reason: StaleThreadReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(reason.headline, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(reason.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Discard", role: .destructive) {
                    appState.denyDraft(draft)
                }
                .disabled(isBusy)
                Button("Regenerate") {
                    Task { await appState.regeneratePendingDraft(draft) }
                }
                .disabled(isBusy)
                Button("\(appState.approveActionLabel) anyway") {
                    Task { await appState.approvePendingDraft(draft, withEditedBody: editedBody, force: true) }
                }
                .disabled(isBusy)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }
}
