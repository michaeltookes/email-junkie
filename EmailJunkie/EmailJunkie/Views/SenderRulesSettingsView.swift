import SwiftUI

/// The "Sender Rules" tab of Settings (item 18): the allowlist of senders to
/// always draft and the blocklist of senders to never draft. Edits are persisted
/// immediately and take effect on the next inbox poll — no restart needed.
struct SenderRulesSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Text(
                    "Choose senders the watcher should always draft, or never draft. "
                    + "Enter a full address (alice@example.com) or a whole domain (example.com). "
                    + "Changes take effect on the next inbox check — no restart needed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SenderRuleListSection(
                title: "Always draft (allowlist)",
                placeholder: "alice@example.com or example.com",
                emptyHint: "No allowlisted senders yet.",
                addAccessibilityLabel: "Add sender to allowlist",
                rules: appState.senderAllowlist,
                onAdd: { appState.addAllowedSender($0) },
                onDelete: { appState.removeAllowedSenders(atOffsets: $0) }
            )

            SenderRuleListSection(
                title: "Never draft (blocklist)",
                placeholder: "spammer@example.com or example.com",
                emptyHint: "No blocklisted senders yet.",
                addAccessibilityLabel: "Add sender to blocklist",
                rules: appState.senderBlocklist,
                onAdd: { appState.addBlockedSender($0) },
                onDelete: { appState.removeBlockedSenders(atOffsets: $0) }
            )
        }
        .formStyle(.grouped)
    }
}

/// One allow/blocklist section: an add field plus the current rules with delete.
private struct SenderRuleListSection: View {
    let title: String
    let placeholder: String
    let emptyHint: String
    let addAccessibilityLabel: String
    let rules: [SenderRule]
    let onAdd: (String) -> Bool
    let onDelete: (IndexSet) -> Void

    @State private var entry = ""

    private var isEntryEmpty: Bool {
        entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section(title) {
            HStack {
                TextField(placeholder, text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityLabel(addAccessibilityLabel)
                Button("Add", action: add)
                    .disabled(isEntryEmpty)
            }

            if rules.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
                .onDelete(perform: onDelete)
            }
        }
    }

    private func ruleRow(_ rule: SenderRule) -> some View {
        HStack {
            Image(systemName: rule.kind == .address ? "person.crop.circle" : "globe")
                .foregroundStyle(.secondary)
            Text(rule.pattern)
            Spacer()
            Text(rule.kindLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rule.kindLabel) rule \(rule.pattern)")
    }

    private func add() {
        guard onAdd(entry) else { return }
        entry = ""
    }
}
