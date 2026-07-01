import SwiftUI

/// The app's settings window.
///
/// For the shell milestone this exposes the working "launch at login" and
/// "poll interval" controls and placeholders for the features still to come
/// (Gmail account, AI provider, send behavior).
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))

                Stepper(
                    "Inbox poll interval: \(appState.pollIntervalSeconds)s",
                    value: $appState.pollIntervalSeconds,
                    in: 30...3600,
                    step: 30
                )
            }

            Section("Email account") {
                LabeledContent("Status") {
                    Text(appState.isAccountConnected ? "Connected" : "Not connected")
                        .foregroundStyle(.secondary)
                }
                Text("Gmail connection is coming soon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI provider") {
                Text("Bring-your-own provider and local-model support are coming soon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 360)
    }
}
