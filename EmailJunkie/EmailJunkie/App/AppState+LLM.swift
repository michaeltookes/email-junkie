import Foundation

/// LLM-provider actions on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// The model to use: the user's choice, or the provider default if blank.
    var resolvedLLMModel: String {
        let trimmed = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? llmProviderKind.defaultModel : trimmed
    }

    /// Recomputes whether the current key is verified for the currently
    /// selected provider/model pair.
    func refreshLLMConnectionStatus() {
        isLLMConnected = secrets.hasValue(for: llmProviderKind.apiKeySecret)
            && resolvedLLMModel == verifiedLLMModel
    }

    /// Switches the selected provider, reloading its stored key and status.
    /// (With a single provider today this is a no-op path; it's the seam for
    /// when a second adapter lands.)
    func selectLLMProvider(_ provider: LLMProviderKind) {
        guard provider != llmProviderKind else { return }
        llmProviderKind = provider
        llmAPIKey = ((try? secrets.value(for: provider.apiKeySecret)) ?? nil) ?? ""
        verifiedLLMModel = ""
        refreshLLMConnectionStatus()
        llmError = nil
        saveSettings()
    }

    /// Verifies the API key with a live test call and, on success, stores it.
    func testLLMConnection() async {
        llmError = nil

        let key = llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            llmError = "Enter an API key first."
            return
        }

        isTestingLLM = true
        defer { isTestingLLM = false }

        let testedProvider = llmProviderKind
        let testedModel = resolvedLLMModel

        do {
            try await llm.testConnection(provider: testedProvider, apiKey: key, model: testedModel)
        } catch {
            llmError = Self.llmMessage(for: error)
            return
        }

        guard llmProviderKind == testedProvider,
              resolvedLLMModel == testedModel,
              llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) == key else {
            llmError = "Connection settings changed. Test again."
            refreshLLMConnectionStatus()
            return
        }

        do {
            try secrets.set(key, for: testedProvider.apiKeySecret)
        } catch {
            llmError = Self.keychainLLMMessage(action: "save", error: error)
            return
        }

        verifiedLLMModel = testedModel
        saveSettings()
        isLLMConnected = true
    }

    /// Disconnects the provider by clearing its stored API key.
    func disconnectLLM() {
        llmError = nil
        do {
            try secrets.remove(llmProviderKind.apiKeySecret)
        } catch {
            llmError = Self.keychainLLMMessage(action: "remove", error: error)
            return
        }
        llmAPIKey = ""
        verifiedLLMModel = ""
        refreshLLMConnectionStatus()
        saveSettings()
    }

    // MARK: - Error messages

    static func llmMessage(for error: Error) -> String {
        switch error {
        case LLMError.missingAPIKey:
            return "Enter an API key first."
        case LLMError.transport(let detail):
            return "Couldn't reach the provider. (\(detail))"
        case LLMError.http(let status, let message):
            return "The provider rejected the request (HTTP \(status)). \(message)"
        case LLMError.invalidResponse(let detail):
            return "Unexpected response from the provider. (\(detail))"
        case KeychainError.unexpectedStatus(let status):
            return "Keychain returned status \(status)."
        case KeychainError.dataEncodingFailed:
            return "Keychain could not encode the API key."
        default:
            return error.localizedDescription
        }
    }

    static func keychainLLMMessage(action: String, error: Error) -> String {
        "Couldn't \(action) the API key in Keychain. \(llmMessage(for: error))"
    }
}
