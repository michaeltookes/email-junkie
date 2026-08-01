import SwiftUI

/// A sheet showing the readable body text of a fetched message. Shared by the
/// Settings "Recent messages" section and the mailbox browser (item 40).
struct MessageBodyView: View {
    let preview: MailBodyPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(preview.subject.isEmpty ? "(no subject)" : preview.subject)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            ScrollView {
                Text(preview.text.isEmpty ? "(no text content)" : preview.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 480, height: 420)
    }
}

/// A sheet showing a generated reply draft, with a send/save action reflecting
/// the current `SendBehavior`. Shared by Settings and the mailbox browser.
struct DraftView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var displayedDraft: Draft
    @State private var isDispatching = false
    @State private var dispatchConfirmation: String?
    @State private var dispatchError: String?
    @State private var staleReason: StaleThreadReason?

    init(draft: Draft) {
        _displayedDraft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayedDraft.replySubject)
                        .font(.headline)
                        .lineLimit(2)
                    if let recipient = displayedDraft.sourceReplyTo?.email ?? displayedDraft.sourceFrom?.email {
                        Text("To: \(recipient)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            ScrollView {
                if let needsInfo = displayedDraft.needsInfo {
                    DraftNeedsInfoView(needsInfo: needsInfo)
                        .padding()
                } else {
                    Text(displayedDraft.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            Divider()
            HStack {
                if let confirmation = dispatchConfirmation {
                    Label(confirmation, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let error = dispatchError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                // A flagged draft has no reply to send — offer no dispatch action.
                if !displayedDraft.isFlagged {
                    Button {
                        Task { await approveDisplayedDraft() }
                    } label: {
                        if isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(appState.sendBehavior == .autoSend ? "Send now" : "Save to Drafts")
                        }
                    }
                    .disabled(isBusy || isDone)
                }
            }
            .padding()
        }
        .frame(width: 480, height: 460)
        .confirmationDialog(
            staleReason?.headline ?? "",
            isPresented: staleWarningBinding,
            titleVisibility: .visible
        ) {
            Button(appState.sendBehavior == .autoSend ? "Send anyway" : "Save anyway", role: .destructive) {
                Task { await approveDisplayedDraft(force: true) }
            }
            Button("Regenerate") {
                Task { await regenerateDisplayedDraft() }
            }
            Button("Cancel", role: .cancel) { staleReason = nil }
        } message: {
            if let staleReason {
                Text(staleReason.detail)
            }
        }
    }

    private var staleWarningBinding: Binding<Bool> {
        Binding(
            get: { staleReason != nil },
            set: { if !$0 { staleReason = nil } }
        )
    }

    private func approveDisplayedDraft(force: Bool = false) async {
        guard !isDispatching else { return }
        dispatchConfirmation = nil
        dispatchError = nil
        isDispatching = true
        defer { isDispatching = false }

        do {
            dispatchConfirmation = try await appState.approveDraftPreview(displayedDraft, force: force)
            staleReason = nil
        } catch let error as DraftDispatchError {
            if case .staleThread(let reason) = error {
                staleReason = reason
            } else {
                dispatchError = AppState.draftMessage(for: error)
            }
        } catch {
            dispatchError = AppState.draftMessage(for: error)
        }
    }

    private func regenerateDisplayedDraft() async {
        guard !isDispatching else { return }
        dispatchConfirmation = nil
        dispatchError = nil
        staleReason = nil
        isDispatching = true
        defer { isDispatching = false }

        do {
            displayedDraft = try await appState.regenerateDraftPreview(displayedDraft)
        } catch {
            dispatchError = AppState.draftMessage(for: error)
        }
    }

    private var isBusy: Bool {
        isDispatching
    }

    private var isDone: Bool {
        dispatchConfirmation != nil
    }
}
