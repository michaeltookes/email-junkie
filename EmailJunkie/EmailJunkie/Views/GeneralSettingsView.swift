import SwiftUI

/// The "General" tab of Settings: app-wide preferences that aren't tied to a
/// specific account or AI provider (item 48 split the single scrolling form into
/// dedicated tabs).
struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))
                .accessibilityLabel("Launch Email Junkie at login")

                Stepper(
                    "Inbox poll interval: \(appState.pollIntervalSeconds)s",
                    value: $appState.pollIntervalSeconds,
                    in: 30...3600,
                    step: 30
                )
                .accessibilityLabel("Inbox poll interval in seconds")

                Picker("On approve", selection: $appState.sendBehavior) {
                    Text("Save as draft").tag(SendBehavior.saveAsDraft)
                    Text("Send immediately").tag(SendBehavior.autoSend)
                }
                .accessibilityLabel("What approving a draft does")
                Text(appState.sendBehavior == .autoSend
                     ? "Approving a draft sends it right away over SMTP."
                     : "Approving a draft saves it to your Gmail Drafts to send yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.sendBehavior == .autoSend {
                    Picker("Undo window", selection: $appState.sendDelaySeconds) {
                        Text("Off (send instantly)").tag(0)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("60 seconds").tag(60)
                    }
                    .accessibilityLabel("Auto-send undo window")
                    Text(appState.sendDelaySeconds > 0
                         ? "After you approve, Email Junkie waits "
                           + "\(appState.sendDelaySeconds)s so you can cancel before it sends."
                         : "Approved drafts send immediately with no cancel window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Text(AppState.privacyStatement)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
