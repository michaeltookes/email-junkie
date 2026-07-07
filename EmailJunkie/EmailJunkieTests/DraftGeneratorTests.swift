import XCTest
@testable import EmailJunkie

final class DraftGeneratorTests: XCTestCase {

    private func context() -> ReplyContext {
        ReplyContext(
            senderName: "Alice",
            senderEmail: "alice@example.com",
            subject: "Lunch Thursday?",
            body: "Are you free for lunch Thursday at noon?"
        )
    }

    private func profile() -> VoiceProfile {
        VoiceProfile(
            greeting: "Hey,", signOff: "Cheers,\nM", formality: "casual", tone: "warm",
            averageLength: "short", commonPhrases: ["Sounds good"], summary: "Brief and warm.",
            sampleCount: 5, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testBuildsPromptWithIncomingMessageAndVoiceProfile() async throws {
        var captured: LLMRequest?
        let generator = DraftGenerator()

        _ = try await generator.makeDraft(
            replyingTo: context(),
            voiceProfile: profile(),
            model: "claude-sonnet-4-6"
        ) { request in
            captured = request
            return LLMResponse(text: "Sounds good — see you Thursday!")
        }

        let system = try XCTUnwrap(captured?.system)
        XCTAssertTrue(system.contains("Greeting: Hey,"), "voice profile must be injected")
        let user = try XCTUnwrap(captured?.messages.first?.content)
        XCTAssertTrue(user.contains("Alice <alice@example.com>"))
        XCTAssertTrue(user.contains("Lunch Thursday?"))
        XCTAssertTrue(user.contains("Are you free for lunch"))
        XCTAssertEqual(captured?.model, "claude-sonnet-4-6")
    }

    func testUsesNeutralVoiceWhenNoProfile() async throws {
        var captured: LLMRequest?
        let generator = DraftGenerator()

        _ = try await generator.makeDraft(
            replyingTo: context(),
            voiceProfile: nil,
            model: "m"
        ) { request in
            captured = request
            return LLMResponse(text: "Yes, noon works.")
        }

        XCTAssertTrue(try XCTUnwrap(captured?.system).contains("natural, concise, and professional"))
    }

    func testReturnsCleanedReplyBody() async throws {
        let generator = DraftGenerator()

        let body = try await generator.makeDraft(
            replyingTo: context(),
            voiceProfile: nil,
            model: "m"
        ) { _ in LLMResponse(text: "Subject: Re: Lunch Thursday?\n\nYes, noon works for me!\n") }

        XCTAssertEqual(body, "Yes, noon works for me!", "leading Subject line and whitespace stripped")
    }

    func testEmptyReplyThrows() async {
        let generator = DraftGenerator()

        do {
            _ = try await generator.makeDraft(
                replyingTo: context(),
                voiceProfile: nil,
                model: "m"
            ) { _ in LLMResponse(text: "   \n\n") }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DraftError, .emptyDraft)
        }
    }

    func testTruncatesLongIncomingBody() async throws {
        var captured: LLMRequest?
        var generator = DraftGenerator()
        generator.maxIncomingChars = 50
        let long = ReplyContext(
            senderName: nil, senderEmail: "a@mail.com",
            subject: "Long", body: String(repeating: "x", count: 500)
        )

        _ = try await generator.makeDraft(replyingTo: long, voiceProfile: nil, model: "m") { request in
            captured = request
            return LLMResponse(text: "ok")
        }

        // The 500-char body is capped; the prompt shouldn't carry all of it.
        let xCount = (captured?.messages.first?.content ?? "").filter { $0 == "x" }.count
        XCTAssertEqual(xCount, 50)
    }
}
