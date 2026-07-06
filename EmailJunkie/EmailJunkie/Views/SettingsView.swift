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
                if appState.isAccountConnected {
                    LabeledContent("Status") {
                        Text("Connected").foregroundStyle(.green)
                    }
                    LabeledContent("Account") {
                        Text(appState.mailEmail).foregroundStyle(.secondary)
                    }
                    Button("Disconnect", role: .destructive) {
                        appState.disconnectMail()
                    }
                } else {
                    TextField("Email address", text: $appState.mailEmail)
                        .textContentType(.username)
                    SecureField("App password", text: $appState.mailAppPassword)

                    Button {
                        Task { await appState.testConnection() }
                    } label: {
                        if appState.isConnecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(appState.isConnecting)

                    DisclosureGroup("How do I get an app password?") {
                        Text("In your Google Account, turn on 2-Step Verification, then go "
                             + "to Security \u{2192} App passwords and generate one. Paste the "
                             + "16-character password here \u{2014} no Google Cloud setup "
                             + "needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("Advanced (IMAP server)") {
                        TextField("IMAP host", text: $appState.mailHost)
                        TextField("Port", value: $appState.mailPort, format: .number)
                    }
                }

                if let error = appState.connectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if appState.isAccountConnected {
                Section("Recent messages") {
                    Button {
                        Task { await appState.previewRecentMessages() }
                    } label: {
                        if appState.isFetching {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Preview inbox")
                        }
                    }
                    .disabled(appState.isFetching)

                    if let error = appState.fetchError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ForEach(appState.recentMessages) { message in
                        Button {
                            Task { await appState.previewBody(for: message) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(message.from?.email ?? "unknown sender")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if appState.isFetchingBody {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isFetchingBody)
                    }

                    if let error = appState.bodyError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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
        .sheet(item: $appState.openedBody) { preview in
            MessageBodyView(preview: preview)
        }
    }
}

/// A sheet showing the readable body text of a fetched message.
private struct MessageBodyView: View {
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
