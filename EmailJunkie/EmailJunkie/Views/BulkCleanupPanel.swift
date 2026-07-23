import EmailJunkieMail
import SwiftUI

/// The bulk-cleanup panel inside the mailbox browser (item 42).
///
/// Deliberately a two-step flow: **Preview** scans and reports what the current
/// filter matches, and only then does a run button appear. Destructive actions
/// additionally require confirming an alert that names the exact count, so mail
/// is never moved on a single mis-click.
struct BulkCleanupPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow
            if let preview = appState.bulk.preview {
                previewSummary(preview)
            }
            statusRow
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .alert("Confirm cleanup", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button(appState.bulk.action.verb, role: destructiveRole) {
                Task { await appState.applyBulkCleanup() }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - Controls

    private var actionRow: some View {
        HStack(spacing: 8) {
            Picker("Cleanup", selection: $appState.bulk.action) {
                Text("Mark read").tag(MailBulkAction.markRead)
                Text("Archive").tag(MailBulkAction.archive)
                Text("Move to Trash").tag(MailBulkAction.moveToTrash)
            }
            .labelsHidden()
            .frame(width: 160)
            .disabled(isBusy)

            Button("Preview cleanup") {
                Task { await appState.previewBulkCleanup() }
            }
            .disabled(isBusy)
            .help("Count what the current filter matches, without changing anything")

            if appState.bulk.canApply {
                Button(appState.bulk.action.verb) {
                    if appState.bulk.action.isDestructive {
                        isConfirming = true
                    } else {
                        Task { await appState.applyBulkCleanup() }
                    }
                }
                .keyboardShortcut(.none)
                .help("Apply to every message the preview matched")
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func previewSummary(_ preview: MailBulkPreview) -> some View {
        if preview.matchCount == 0 {
            Text("Nothing matches that filter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryText(preview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(preview.sample.prefix(3)) { message in
                    Text("• \(message.from?.email ?? "unknown") — \(displaySubject(message))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if preview.sample.count > 3 {
                    Text("…and \(preview.matchCount - 3) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if appState.bulk.isPreviewing {
            label("Scanning mailbox…", showsSpinner: true)
        } else if appState.bulk.isApplying {
            label(progressText, showsSpinner: true)
        } else if let message = appState.bulk.completionMessage {
            Text(message).font(.caption).foregroundStyle(.green)
        }

        if let error = appState.bulk.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func label(_ text: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 6) {
            if showsSpinner { ProgressView().controlSize(.small) }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var isBusy: Bool {
        appState.bulk.isPreviewing || appState.bulk.isApplying
    }

    private var destructiveRole: ButtonRole? {
        appState.bulk.action == .moveToTrash ? .destructive : nil
    }

    private var progressText: String {
        guard let progress = appState.bulk.progress, progress.total > 0 else {
            return "Working…"
        }
        return "\(appState.bulk.action.verb): \(progress.processed) of \(progress.total)…"
    }

    private var confirmationMessage: String {
        guard let preview = appState.bulk.preview else { return "" }
        return AppState.bulkConfirmationMessage(
            for: appState.bulk.action,
            matchCount: preview.matchCount,
            isPartial: preview.isPartial
        )
    }

    private func summaryText(_ preview: MailBulkPreview) -> String {
        let noun = preview.matchCount == 1 ? "message" : "messages"
        let count = preview.isPartial ? "At least \(preview.matchCount)" : "\(preview.matchCount)"
        let action = appState.bulk.previewAction ?? appState.bulk.action
        let qualifier = action == .markRead ? "unread " : ""
        return "\(count) \(qualifier)\(noun) match — \(action.verb.lowercased()) will apply to all of them."
    }

    private func displaySubject(_ message: MailMessage) -> String {
        message.subject.isEmpty ? "(no subject)" : message.subject
    }
}
