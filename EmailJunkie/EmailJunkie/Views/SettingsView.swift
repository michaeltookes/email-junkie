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

            Section("Email account (Gmail)") {
                if appState.isAccountConnected {
                    LabeledContent("Status") {
                        Text("Connected").foregroundStyle(.green)
                    }
                    Button("Disconnect", role: .destructive) {
                        appState.disconnectGmail()
                    }
                } else {
                    TextField("Google client ID", text: $appState.clientIDInput)
                        .textContentType(.username)
                    SecureField("Google client secret", text: $appState.clientSecretInput)

                    Button {
                        Task { await appState.connectGmail() }
                    } label: {
                        if appState.isConnecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect Gmail")
                        }
                    }
                    .disabled(appState.isConnecting)

                    DisclosureGroup("How do I get these?") {
                        Text("In Google Cloud: create a project, enable the Gmail API, "
                             + "configure the OAuth consent screen, then create an OAuth "
                             + "client ID of type \u{201C}Desktop app.\u{201D} Paste its client "
                             + "ID and secret here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = appState.connectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("AI provider") {
                Text("Bring-your-own provider and local-model support are coming soon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Email Junkie is local-first. Your mail and settings stay on this "
                     + "Mac, and secrets like API keys and OAuth tokens are stored in the "
                     + "macOS Keychain — never in plaintext. Nothing leaves your machine "
                     + "except the LLM request you configure and control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
    }
}
