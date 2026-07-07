import XCTest
@testable import EmailJunkie

final class VoiceProfileTests: XCTestCase {

    private func sample(commonPhrases: [String] = ["Sounds good"], tone: String = "warm") -> VoiceProfile {
        VoiceProfile(
            greeting: "Hi,",
            signOff: "Best,\nMichael",
            formality: "casual",
            tone: tone,
            averageLength: "short",
            commonPhrases: commonPhrases,
            summary: "Brief and warm.",
            sampleCount: 5,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testRoundTripsThroughCodable() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VoiceProfile.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testPromptBlockIncludesPopulatedFields() {
        let block = sample().promptBlock()
        XCTAssertTrue(block.contains("Greeting: Hi,"))
        XCTAssertTrue(block.contains("Sign-off: Best,"))
        XCTAssertTrue(block.contains("Tone: warm"))
        XCTAssertTrue(block.contains("Recurring phrases: Sounds good"))
    }

    func testPromptBlockOmitsEmptyFields() {
        let block = sample(commonPhrases: [], tone: "").promptBlock()
        XCTAssertFalse(block.contains("Tone:"))
        XCTAssertFalse(block.contains("Recurring phrases:"))
        XCTAssertTrue(block.contains("Greeting: Hi,"))
    }
}
