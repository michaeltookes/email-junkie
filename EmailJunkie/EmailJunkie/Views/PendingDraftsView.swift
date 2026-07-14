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
        }
        .frame(width: 720, height: 520)
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

/// A single reviewable draft: incoming message on the left, proposed reply on
/// the right, with Approve / Deny actions.
private struct PendingDraftCard: View {
    let draft: Draft
    @EnvironmentObject var appState: AppState

    private var isBusy: Bool { appState.approvingDraftIDs.contains(draft.identity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                incomingColumn
                Divider()
                replyColumn
            }
            Divider()
            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
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

    private var replyColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Proposed reply")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            if let recipient = draft.sourceReplyTo?.email ?? draft.sourceFrom?.email {
                Text("To: \(recipient)").font(.caption).foregroundStyle(.secondary)
            }
            Text(draft.replySubject)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(draft.body)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Deny", role: .destructive) {
                appState.denyDraft(draft)
            }
            .disabled(isBusy)

            Button(appState.approveActionLabel) {
                Task { await appState.approveDraft(draft) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
        }
    }
}
