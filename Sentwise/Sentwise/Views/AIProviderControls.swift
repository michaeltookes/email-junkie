import SwiftUI

/// Shared AI-provider controls used by both onboarding and Settings (item 56a):
/// the managed-inference sign-in card and the bring-your-own-provider controls.
/// Extracted from `OnboardingView` to keep that file within length limits.

/// The primary, pre-selected managed-inference option: sign in and draft, no key.
struct ManagedInferenceCard: View {
    @EnvironmentObject var appState: AppState

    private var isHuntMode: Bool { ProwlHuntRuntime.current.isEnabled }
    private var isSelected: Bool { appState.llmProviderKind == .managed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Sentwise AI — included with your subscription").font(.callout).bold()
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Text("Nothing to set up — no API key, no billing beyond Sentwise. 14-day free trial.")
                .font(.caption).foregroundStyle(.secondary)

            if !isSelected {
                Button("Use Sentwise AI") { appState.selectLLMProvider(.managed) }
                    .accessibilityIdentifier("useManagedInference")
            } else if appState.isManagedSignedIn {
                ConnectedBadge(text: "Connected as \(appState.managedAccountEmail)")
                Button("Sign out") { Task { await appState.signOutManaged() } }
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedSignOutButton")
            } else {
                ManagedSignInControls()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

/// Email-code sign-in controls for the managed account.
struct ManagedSignInControls: View {
    @EnvironmentObject var appState: AppState

    private var isHuntMode: Bool { ProwlHuntRuntime.current.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.managedSignInStage == .idle {
                TextField("Email address", text: $appState.managedEmailInput)
                    .textContentType(.username)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("managedEmailField")
                Button {
                    Task { await appState.startManagedSignIn() }
                } label: {
                    signInLabel(busy: appState.isManagedBusy, title: "Send sign-in code")
                }
                .disabled(appState.isManagedBusy || isHuntMode)
                .accessibilityIdentifier("managedSendCodeButton")
            } else {
                Text("Enter the code we emailed to \(appState.managedEmailInput).")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("6-digit code", text: $appState.managedCodeInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("managedCodeField")
                HStack {
                    Button {
                        Task { await appState.verifyManagedCode() }
                    } label: {
                        signInLabel(busy: appState.isManagedBusy, title: "Verify & connect")
                    }
                    .disabled(appState.isManagedBusy || isHuntMode)
                    .accessibilityIdentifier("managedVerifyButton")
                    Button("Use a different email") {
                        appState.managedSignInStage = .idle
                        appState.managedCodeInput = ""
                        appState.managedError = nil
                    }
                    .buttonStyle(.link)
                }
            }
            if isHuntMode {
                Text("Sign-in is disabled during Prowl hunts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = appState.managedError {
                OnboardingError(message: error)
            }
        }
        // A stale error shouldn't linger once the user starts correcting it.
        .onChange(of: appState.managedEmailInput) { _, _ in appState.managedError = nil }
        .onChange(of: appState.managedCodeInput) { _, _ in appState.managedError = nil }
    }

    @ViewBuilder
    private func signInLabel(busy: Bool, title: String) -> some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            Text(title)
        }
    }
}

/// The bring-your-own-provider controls (picker + model + base URL + key + test).
/// Managed is excluded from the picker here — it lives in its own card above.
struct BYOProviderControls: View {
    @EnvironmentObject var appState: AppState

    private var byoProviders: [LLMProviderKind] {
        LLMProviderKind.allCases.filter { $0 != .managed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Provider", selection: Binding(
                get: { appState.llmProviderKind == .managed ? (byoProviders.first ?? .anthropic) : appState.llmProviderKind },
                set: { appState.selectLLMProvider($0) }
            )) {
                ForEach(byoProviders) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityIdentifier("byoProviderPicker")

            if appState.llmProviderKind != .managed {
                TextField("Model", text: modelBinding, prompt: Text(appState.llmProviderKind.defaultModel))
                    .textFieldStyle(.roundedBorder)

                if appState.llmProviderKind.supportsCustomBaseURL {
                    TextField(
                        "Base URL (optional)",
                        text: baseURLBinding,
                        prompt: Text(appState.llmProviderKind.baseURLPlaceholder ?? "")
                    )
                    .textFieldStyle(.roundedBorder)
                }

                if appState.isLLMConnected {
                    ConnectedBadge(text: "Connected")
                    Button("Disconnect", role: .destructive) { appState.disconnectLLM() }
                } else {
                    SecureField(apiKeyFieldTitle, text: $appState.llmAPIKey)
                        .textFieldStyle(.roundedBorder)
                    if !appState.llmProviderKind.requiresAPIKey {
                        Text("Optional — leave blank for Ollama or unauthenticated local runtimes.")
                            .font(.caption).foregroundStyle(.secondary)
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
                }
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { appState.llmModel },
            set: {
                appState.llmModel = $0
                appState.refreshLLMConnectionStatus()
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { appState.llmBaseURL },
            set: { appState.updateLLMBaseURLFromUser($0) }
        )
    }

    private var apiKeyFieldTitle: String {
        appState.llmProviderKind.requiresAPIKey ? "API key" : "API key (optional)"
    }
}
