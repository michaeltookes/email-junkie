import Foundation

/// The incoming message being replied to.
struct ReplyContext: Equatable {
    var senderName: String?
    var senderEmail: String?
    var subject: String
    var body: String
}

/// Errors specific to draft generation.
enum DraftError: Error, Equatable {
    /// The model returned no usable reply text.
    case emptyDraft
    /// The selected source mailbox cannot produce a safe reply recipient.
    case unsupportedSourceMailbox
}

/// Produces a reply body from an incoming message and the user's voice profile
/// by prompting an LLM.
///
/// Pure and network-free: the caller injects a `complete` closure (backed by
/// `LLMProviding` in the app, a stub in tests), so prompt construction and
/// output cleaning are unit-testable. Mirrors `VoiceProfiler`.
struct DraftGenerator {
    typealias Complete = (LLMRequest) async throws -> LLMResponse

    /// Per-message character cap on the incoming body (bounds token cost).
    var maxIncomingChars = 4000

    func makeDraft(
        replyingTo context: ReplyContext,
        voiceProfile: VoiceProfile?,
        model: String,
        complete: Complete
    ) async throws -> String {
        let request = LLMRequest(
            system: Self.systemPrompt(voiceProfile: voiceProfile),
            messages: [LLMMessage(role: .user, content: Self.userPrompt(context, maxChars: maxIncomingChars))],
            model: model,
            maxTokens: 1024,
            temperature: 0.7
        )
        let response = try await complete(request)
        let body = Self.cleaned(response.text)
        guard !body.isEmpty else { throw DraftError.emptyDraft }
        return body
    }

    // MARK: - Prompt

    static func systemPrompt(voiceProfile: VoiceProfile?) -> String {
        let base = """
        You are the user's personal email assistant. Write a reply to the email \
        the user received, as if the user wrote it themselves. Output ONLY the \
        reply body — no subject line, no "Subject:" prefix, no quoted original \
        text, and no meta commentary like "Here's a draft". Match the intent of \
        the incoming email and keep the reply appropriate in length and tone.
        """
        let voice = voiceProfile?.promptBlock()
            ?? "Write in a natural, concise, and professional tone."
        return base + "\n\n" + voice
    }

    private static func userPrompt(_ context: ReplyContext, maxChars: Int) -> String {
        let sender = senderLine(context)
        let body = String(context.body.prefix(maxChars))
        return """
        Reply to this email:

        From: \(sender)
        Subject: \(context.subject)

        \(body)
        """
    }

    private static func senderLine(_ context: ReplyContext) -> String {
        switch (context.senderName, context.senderEmail) {
        case let (name?, email?) where !name.isEmpty:
            return "\(name) <\(email)>"
        case let (_, email?):
            return email
        case let (name?, nil) where !name.isEmpty:
            return name
        default:
            return "(unknown sender)"
        }
    }

    // MARK: - Output cleaning

    /// Trims the reply and strips a stray leading `Subject:` line the model may
    /// add despite instructions.
    static func cleaned(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("subject:")
              || first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
