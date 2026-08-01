import Foundation

/// LLM-provider actions on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// The model to use: the user's choice, or the provider default if blank.
    var resolvedLLMModel: String {
        resolvedLLMModel(for: llmModel)
    }

    func resolvedLLMModel(for model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? llmProviderKind.defaultModel : trimmed
    }

    /// The base URL to pass to the LLM layer for the current provider: the
    /// user's override when the provider is endpoint-configurable and a value is
    /// set, otherwise `nil` (provider default). Providers that don't support a
    /// custom endpoint always resolve to `nil`, so a stale value left over from
    /// another provider is ignored.
    var currentLLMBaseURL: String? {
        guard llmProviderKind.supportsCustomBaseURL else { return nil }
        let trimmed = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Applies a user edit to the custom base URL. Because the endpoint is part
    /// of what a connection test verifies, editing it clears the verified state
    /// so the user must re-test before the provider counts as connected.
    func updateLLMBaseURLFromUser(_ newValue: String) {
        guard newValue != llmBaseURL else { return }
        let previousOrigin = currentLLMEndpointOrigin
        llmBaseURL = newValue
        let shouldClearKey = llmProviderKind.supportsCustomBaseURL
            && shouldClearLLMAPIKeyForEndpointChange(from: previousOrigin, to: currentLLMEndpointOrigin)
        llmError = nil
        if shouldClearKey {
            clearLLMAPIKeyForEndpointChange()
        }
        verifiedLLMModel = ""
        refreshLLMConnectionStatus()
        resetDraftPreviewForLLMChange()
        saveSettings()
    }

    /// Recomputes whether the current key is verified for the currently
    /// selected provider/model pair.
    func refreshLLMConnectionStatus(llmModel model: String? = nil) {
        isLLMConnected = secrets.hasValue(for: llmProviderKind.apiKeySecret)
            && resolvedLLMModel(for: model ?? llmModel) == verifiedLLMModel
    }

    /// Switches the selected provider, reloading its stored key and status.
    /// The model field is cleared so the new provider starts from its default
    /// instead of reusing another provider's model id.
    func selectLLMProvider(_ provider: LLMProviderKind) {
        guard provider != llmProviderKind else { return }
        llmProviderKind = provider
        llmModel = ""
        llmAPIKey = ((try? secrets.value(for: provider.apiKeySecret)) ?? nil) ?? ""
        verifiedLLMModel = ""
        refreshLLMConnectionStatus()
        resetDraftPreviewForLLMChange()
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
        let testedBaseURL = currentLLMBaseURL

        do {
            try await llm.testConnection(
                provider: testedProvider,
                apiKey: key,
                model: testedModel,
                baseURL: testedBaseURL
            )
        } catch {
            llmError = Self.llmMessage(for: error)
            return
        }

        guard llmProviderKind == testedProvider,
              resolvedLLMModel == testedModel,
              currentLLMBaseURL == testedBaseURL,
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
        resetDraftPreviewForLLMChange()
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
        resetDraftPreviewForLLMChange()
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
        case LLMError.invalidBaseURL(let value):
            return "Invalid base URL: \(value). Enter a full http(s) URL, e.g. https://api.openai.com/v1."
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

    private var currentLLMEndpointOrigin: String? {
        guard let endpoint = try? OpenAICompatibleClient.resolveEndpoint(baseURL: currentLLMBaseURL),
              let scheme = endpoint.scheme?.lowercased(),
              let host = endpoint.host?.lowercased() else {
            return nil
        }
        let port = endpoint.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func shouldClearLLMAPIKeyForEndpointChange(from oldOrigin: String?, to newOrigin: String?) -> Bool {
        oldOrigin != newOrigin || oldOrigin == nil || newOrigin == nil
    }

    private func clearLLMAPIKeyForEndpointChange() {
        llmAPIKey = ""
        do {
            try secrets.remove(llmProviderKind.apiKeySecret)
        } catch {
            llmError = Self.keychainLLMMessage(action: "remove", error: error)
        }
    }
}
