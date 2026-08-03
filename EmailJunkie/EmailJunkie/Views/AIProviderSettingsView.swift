import SwiftUI

/// The "AI Provider" tab of Settings: LLM provider/model/key selection plus voice
/// learning (which depends on both a connected account and a connected provider).
struct AIProviderSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("AI provider") {
                if LLMProviderKind.allCases.count > 1 {
                    Picker("Provider", selection: Binding(
                        get: { appState.llmProviderKind },
                        set: { appState.selectLLMProvider($0) }
                    )) {
                        ForEach(LLMProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .accessibilityLabel("AI provider")
                } else {
                    LabeledContent("Provider") {
                        Text(appState.llmProviderKind.displayName).foregroundStyle(.secondary)
                    }
                }

                TextField(
                    "Model",
                    text: llmModelBinding,
                    prompt: Text(appState.llmProviderKind.defaultModel)
                )
                .accessibilityLabel("AI model")

                if appState.llmProviderKind.supportsCustomBaseURL {
                    TextField(
                        "Base URL",
                        text: llmBaseURLBinding,
                        prompt: Text(appState.llmProviderKind.baseURLPlaceholder ?? "")
                    )
                    .accessibilityLabel("AI provider base URL")
                    Text(llmBaseURLHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appState.isLLMConnected {
                    LabeledContent("Status") {
                        Text("Connected").foregroundStyle(.green)
                    }
                    Button("Disconnect", role: .destructive) {
                        appState.disconnectLLM()
                    }
                    .accessibilityLabel("Disconnect AI provider")
                } else {
                    SecureField(llmAPIKeyFieldTitle, text: $appState.llmAPIKey)
                        .accessibilityLabel("AI provider API key")

                    if !appState.llmProviderKind.requiresAPIKey {
                        Text("Optional — leave blank for Ollama or unauthenticated local runtimes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await appState.testLLMConnection() }
                    } label: {
                        if appState.isTestingLLM {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(appState.isTestingLLM)
                    .accessibilityLabel("Test AI provider connection")
                }

                if let error = appState.llmError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Voice") {
                if let profile = appState.voiceProfile {
                    Text(profile.summary.isEmpty
                         ? "Learned from \(profile.sampleCount) sent message\(profile.sampleCount == 1 ? "" : "s")."
                         : profile.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Learn your writing voice from your Sent mail so drafts sound like you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await appState.learnVoiceProfile() }
                } label: {
                    if appState.isLearningVoice {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            if let progress = appState.voiceProgress {
                                Text(progress).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(appState.voiceProfile == nil ? "Learn my voice" : "Re-learn")
                    }
                }
                .disabled(appState.isLearningVoice || !appState.canLearnVoice)
                .accessibilityLabel(appState.voiceProfile == nil ? "Learn my voice" : "Re-learn my voice")

                if appState.voiceProfile != nil {
                    Button("Forget voice profile", role: .destructive) {
                        appState.forgetVoiceProfile()
                    }
                    .disabled(appState.isLearningVoice)
                    .accessibilityLabel("Forget voice profile")
                }

                if !appState.canLearnVoice && appState.voiceProfile == nil {
                    Text("Connect an email account and an AI provider first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = appState.voiceError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Endpoint help text tailored to the selected provider.
    private var llmBaseURLHelp: String {
        switch appState.llmProviderKind {
        case .ollama:
            return """
            Leave blank for Ollama (http://localhost:11434/v1). Point this at LM Studio \
            (http://localhost:1234/v1) or another OpenAI-compatible local/LAN server. \
            Remote endpoints must use HTTPS; plain HTTP works only on your local network.
            """
        default:
            return """
            Leave blank for OpenAI. Point this at any OpenAI-compatible endpoint \
            (OpenRouter, Groq, a local server, …). Remote endpoints must use HTTPS; \
            plain HTTP works only on your local network.
            """
        }
    }

    private var llmModelBinding: Binding<String> {
        Binding(
            get: { appState.llmModel },
            set: {
                appState.llmModel = $0
                appState.refreshLLMConnectionStatus()
            }
        )
    }

    private var llmAPIKeyFieldTitle: String {
        appState.llmProviderKind.requiresAPIKey ? "API key" : "API key (optional)"
    }

    private var llmBaseURLBinding: Binding<String> {
        Binding(
            get: { appState.llmBaseURL },
            set: { appState.updateLLMBaseURLFromUser($0) }
        )
    }
}
