import Foundation

/// Drafts a post-call follow-up email from a parsed transcript in the user's
/// learned voice (item 51): a brief recap, agreed next steps / action items with
/// owners, and a proposed next meeting.
///
/// Pure and network-free like `DraftGenerator`: the caller injects a `complete`
/// closure (backed by `LLMProviding` in the app, a stub in tests), so prompt
/// assembly, long-transcript summarization, and output cleaning are unit-testable.
struct FollowUpGenerator {
    typealias Complete = (LLMRequest) async throws -> LLMResponse

    /// Transcripts at or under this length are drafted in a single pass. Longer
    /// ones are summarized chunk-by-chunk first so the request stays within the
    /// model's context window rather than failing (item 51).
    var maxSinglePassChars = 12_000
    /// Target size of each chunk when summarizing a long transcript.
    var maxChunkChars = 8_000
    /// Token ceiling for the follow-up draft itself.
    var maxTokens = 1200

    /// How the transcript is presented to the drafting prompt: the full text, or a
    /// distilled summary when the transcript was too long to send whole.
    private enum DraftSource {
        case full(String)
        case summarized(String)
    }

    /// Produces the follow-up email body. Throws `DraftError.emptyDraft` if the
    /// model returns nothing usable.
    func makeFollowUp(
        transcript: ParsedTranscript,
        voiceProfile: VoiceProfile?,
        model: String,
        complete: Complete
    ) async throws -> String {
        guard !transcript.isEmpty else { throw DraftError.emptyDraft }

        let source: DraftSource
        if transcript.text.count <= maxSinglePassChars {
            source = .full(transcript.text)
        } else {
            let summary = try await summarize(transcript.text, model: model, complete: complete)
            source = .summarized(summary)
        }

        let request = LLMRequest(
            system: Self.systemPrompt(voiceProfile: voiceProfile),
            messages: [LLMMessage(
                role: .user,
                content: Self.userPrompt(source: source, hasSpeakerLabels: transcript.hasSpeakerLabels)
            )],
            model: model,
            maxTokens: maxTokens,
            temperature: 0.6
        )
        let response = try await complete(request)
        let body = DraftGenerator.cleaned(response.text)
        guard !body.isEmpty else { throw DraftError.emptyDraft }
        return body
    }

    // MARK: - Long-transcript summarization

    /// Summarizes an over-long transcript chunk-by-chunk, then concatenates the
    /// per-chunk summaries into a single distilled brief the drafting pass reads.
    private func summarize(_ text: String, model: String, complete: Complete) async throws -> String {
        let chunks = TranscriptChunker.chunk(text, maxChars: maxChunkChars)
        guard chunks.count > 1 else {
            return try await summarizeChunk(chunks.first ?? text, model: model, complete: complete)
        }
        var summaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let summary = try await summarizeChunk(
                chunk,
                partLabel: "part \(index + 1) of \(chunks.count)",
                model: model,
                complete: complete
            )
            if !summary.isEmpty { summaries.append(summary) }
        }
        let combined = summaries.joined(separator: "\n\n")
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DraftError.emptyDraft
        }
        return combined
    }

    private func summarizeChunk(
        _ chunk: String,
        partLabel: String? = nil,
        model: String,
        complete: Complete
    ) async throws -> String {
        let scope = partLabel.map { " (\($0) of the call)" } ?? ""
        let request = LLMRequest(
            system: """
            You are condensing a call transcript so a follow-up email can be written from it. \
            Extract only what matters for the follow-up: decisions made, agreed action items \
            with their owners, deadlines, open questions, and any next meeting discussed. \
            Preserve who said or owns what. Output concise bullet points and nothing else.
            """,
            messages: [LLMMessage(role: .user, content: "Transcript\(scope):\n\n\(chunk)")],
            model: model,
            maxTokens: 700,
            temperature: 0.3
        )
        let response = try await complete(request)
        return DraftGenerator.cleaned(response.text)
    }

    // MARK: - Prompts

    static func systemPrompt(voiceProfile: VoiceProfile?) -> String {
        let base = """
        You are the user's personal email assistant. You are given the transcript of a call \
        the user just had. Write the follow-up email the user would send after that call, as if \
        the user wrote it themselves. Structure it as: a one- or two-sentence recap of the call, \
        the agreed next steps / action items as a short list with the owner named for each, and a \
        proposed next meeting or check-in if one was discussed. Only include a section if the call \
        actually covered it — never invent action items, owners, dates, or commitments that are \
        not supported by the transcript. Output ONLY the email body — no subject line, no \
        "Subject:" prefix, and no meta commentary like "Here's a draft".
        """
        let voice = voiceProfile?.promptBlock()
            ?? "Write in a natural, concise, and professional tone."
        return base + "\n\n" + voice
    }

    private static func userPrompt(source: DraftSource, hasSpeakerLabels: Bool) -> String {
        let speakerNote = hasSpeakerLabels
            ? "The transcript labels each speaker (e.g. \"Name:\"). Use the labels to attribute "
                + "action items to the right owner."
            : "The transcript is not labeled by speaker. Infer owners only where the wording makes "
                + "them clear; otherwise phrase action items without guessing who owns them."
        switch source {
        case .full(let text):
            return """
            Write the follow-up email from this call transcript.

            \(speakerNote)

            Transcript:

            \(text)
            """
        case .summarized(let summary):
            return """
            Write the follow-up email from this distilled summary of a long call. The summary was \
            produced from the full transcript; treat it as the source of truth.

            \(speakerNote)

            Call summary:

            \(summary)
            """
        }
    }
}
