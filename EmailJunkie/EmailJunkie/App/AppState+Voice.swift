import EmailJunkieMail
import Foundation

/// Voice-profile learning on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// How many recent Sent messages to sample when learning.
    static let voiceSampleLimit = 12

    /// Whether the prerequisites for learning are met (mail + AI connected).
    var canLearnVoice: Bool {
        isLLMConnected && mailCredentials.isComplete
    }

    /// Samples the Sent folder and derives a voice profile via the LLM.
    func learnVoiceProfile() async {
        voiceError = nil

        guard let key = ((try? secrets.value(for: llmProviderKind.apiKeySecret)) ?? nil), !key.isEmpty,
              isLLMConnected else {
            voiceError = "Connect an AI provider first (Test Connection above)."
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            voiceError = "Connect an email account first."
            return
        }

        isLearningVoice = true
        voiceProgress = "Finding your sent mail…"
        defer {
            isLearningVoice = false
            voiceProgress = nil
        }

        do {
            let bodies = try await fetchSentSampleBodies(credentials: credentials)
            guard !bodies.isEmpty else {
                voiceError = "No sent messages found to learn from."
                return
            }
            voiceProgress = "Learning your voice from \(bodies.count) message\(bodies.count == 1 ? "" : "s")…"
            let profile = try await makeProfile(fromSentBodies: bodies, apiKey: key)
            persistence.saveVoiceProfile(profile)
            voiceProfile = profile
        } catch {
            voiceError = Self.voiceMessage(for: error)
        }
    }

    /// Clears the learned profile.
    func forgetVoiceProfile() {
        persistence.removeVoiceProfile()
        voiceProfile = nil
        voiceError = nil
    }

    // MARK: - Helpers

    /// Fetches recent Sent messages and reduces each to readable body text.
    private func fetchSentSampleBodies(credentials: MailAccountCredentials) async throws -> [String] {
        let messages = try await mailProvider.fetchRecentMessages(
            credentials,
            mailbox: .sent,
            limit: Self.voiceSampleLimit
        )
        var bodies: [String] = []
        for (index, message) in messages.enumerated() {
            voiceProgress = "Reading message \(index + 1) of \(messages.count)…"
            let data = try await mailProvider.fetchBodyText(
                credentials,
                mailbox: .sent,
                uid: message.id,
                expectedUIDValidity: message.uidValidity
            )
            let text = MailBodyText.plainText(from: data)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bodies.append(text)
            }
        }
        return bodies
    }

    private func makeProfile(fromSentBodies bodies: [String], apiKey: String) async throws -> VoiceProfile {
        let provider = llmProviderKind
        let model = resolvedLLMModel
        return try await VoiceProfiler().makeProfile(
            fromSentBodies: bodies,
            model: model,
            now: Date()
        ) { [llm] request in
            try await llm.complete(request, provider: provider, apiKey: apiKey)
        }
    }

    static func voiceMessage(for error: Error) -> String {
        switch error {
        case VoiceProfileError.noSamples:
            return "No sent messages found to learn from."
        case VoiceProfileError.invalidResponse(let detail):
            return "The model's reply couldn't be understood. (\(detail))"
        case is LLMError:
            return llmMessage(for: error)
        default:
            return message(for: error)
        }
    }
}
