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
    let draft: Draft
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isDispatching = false
    @State private var dispatchConfirmation: String?
    @State private var dispatchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.replySubject)
                        .font(.headline)
                        .lineLimit(2)
                    if let recipient = draft.sourceReplyTo?.email ?? draft.sourceFrom?.email {
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
                Text(draft.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
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
            .padding()
        }
        .frame(width: 480, height: 460)
    }

    private func approveDisplayedDraft() async {
        guard !isDispatching else { return }
        dispatchConfirmation = nil
        dispatchError = nil
        isDispatching = true
        defer { isDispatching = false }

        do {
            dispatchConfirmation = try await appState.approveDraftPreview(draft)
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
