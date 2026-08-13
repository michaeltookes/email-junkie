import XCTest
@testable import EmailJunkie

final class TranscriptParserTests: XCTestCase {

    // MARK: - Format resolution

    func testFormatResolvesFromExtension() {
        XCTAssertEqual(TranscriptFormat(fileExtension: "txt"), .plainText)
        XCTAssertEqual(TranscriptFormat(fileExtension: "MD"), .markdown)
        XCTAssertEqual(TranscriptFormat(fileExtension: "vtt"), .webVTT)
        XCTAssertEqual(TranscriptFormat(fileExtension: "srt"), .subRip)
        XCTAssertNil(TranscriptFormat(fileExtension: "pdf"))
    }

    func testIsSupportedFile() {
        XCTAssertTrue(TranscriptFormat.isSupportedFile(URL(fileURLWithPath: "/tmp/call.vtt")))
        XCTAssertFalse(TranscriptFormat.isSupportedFile(URL(fileURLWithPath: "/tmp/call.mp4")))
    }

    // MARK: - Plain text

    func testPlainTextPreservesSpeakerLabelsAndDetectsThem() {
        let raw = "Marcus: Thanks for the call.\nDana: Anytime — I'll send the deck."
        let parsed = TranscriptParser.parse(raw, format: .plainText)
        XCTAssertEqual(parsed.text, raw)
        XCTAssertTrue(parsed.hasSpeakerLabels)
    }

    func testPlainTextWithoutLabelsIsUnlabeled() {
        let raw = "We agreed to ship the pilot next week.\nBudget still needs sign-off."
        let parsed = TranscriptParser.parse(raw, format: .plainText)
        XCTAssertFalse(parsed.hasSpeakerLabels)
        XCTAssertEqual(parsed.text, raw)
    }

    func testPlainTextCollapsesBlankRunsAndTrims() {
        let raw = "\n\nLine one.\n\n\n\nLine two.\n\n"
        let parsed = TranscriptParser.parse(raw, format: .plainText)
        XCTAssertEqual(parsed.text, "Line one.\n\nLine two.")
    }

    func testTimestampAndURLLinesAreNotMistakenForSpeakers() {
        XCTAssertFalse(TranscriptParser.lineHasSpeakerLabel("12:34 we started the call"))
        XCTAssertFalse(TranscriptParser.lineHasSpeakerLabel("https://example.com/agenda"))
        XCTAssertTrue(TranscriptParser.lineHasSpeakerLabel("Dana Lee: here's the recap"))
    }

    // MARK: - WebVTT

    func testWebVTTVoiceTagsBecomeSpeakerPrefixes() {
        let raw = """
        WEBVTT

        1
        00:00:00.000 --> 00:00:04.000
        <v Marcus>Thanks everyone for joining today.</v>

        2
        00:00:04.000 --> 00:00:08.000
        <v Dana>Happy to be here. Let's dive in.</v>
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(
            parsed.text,
            "Marcus: Thanks everyone for joining today.\nDana: Happy to be here. Let's dive in."
        )
        XCTAssertTrue(parsed.hasSpeakerLabels)
    }

    func testWebVTTMultipleVoiceSpansBecomeSeparateSpeakerLines() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:04.000
        <v Alice>I'll prepare the deck.</v> <v Bob>I'll send pricing.</v>
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(
            parsed.text,
            "Alice: I'll prepare the deck.\nBob: I'll send pricing."
        )
        XCTAssertTrue(parsed.hasSpeakerLabels)
    }

    func testWebVTTMultipleVoiceSpansPreserveUntaggedCueText() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:04.000
        <v Alice>I'll send it.</v> Deadline Friday. <v Bob>Agreed.</v>
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(
            parsed.text,
            "Alice: I'll send it.\nDeadline Friday.\nBob: Agreed."
        )
        XCTAssertTrue(parsed.hasSpeakerLabels)
    }

    func testWebVTTSingleVoiceSpanPreservesUntaggedCueText() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:04.000
        Deadline Friday. <v Alice>I'll send it.</v>
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(
            parsed.text,
            "Deadline Friday.\nAlice: I'll send it."
        )
        XCTAssertTrue(parsed.hasSpeakerLabels)
    }

    func testWebVTTStripsHeaderNotesAndTimestampsWithoutLabels() {
        let raw = """
        WEBVTT
        Kind: captions
        Language: en

        NOTE This recording was auto-generated

        00:00:00.000 --> 00:00:02.000
        Let's get started.

        00:00:02.000 --> 00:00:05.000
        Sounds good.
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(parsed.text, "Let's get started.\nSounds good.")
        XCTAssertFalse(parsed.hasSpeakerLabels)
    }

    func testWebVTTStripsCueIdentifiersWithSpacesAndColons() {
        let raw = """
        WEBVTT

        Chapter 1: kickoff
        00:00:00.000 --> 00:00:02.000
        Dana owns the rollout.
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)

        XCTAssertEqual(parsed.text, "Dana owns the rollout.")
    }

    func testWebVTTPreservesCueTextStartingWithMetadataWords() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000
        NOTE that Dana owns the rollout.
        STYLE guide is due Friday.
        REGION launch depends on legal.
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(
            parsed.text,
            "NOTE that Dana owns the rollout.\nSTYLE guide is due Friday.\nREGION launch depends on legal."
        )
    }

    func testWebVTTPreservesCueIdentifiersStartingWithMetadataWords() {
        let raw = """
        WEBVTT

        NOTE-1
        00:00:00.000 --> 00:00:03.000
        Dana owns the rollout.

        STYLE-guide
        00:00:03.000 --> 00:00:06.000
        The guide is due Friday.

        REGION-a
        00:00:06.000 --> 00:00:09.000
        Legal still needs to approve.
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(
            parsed.text,
            "Dana owns the rollout.\nThe guide is due Friday.\nLegal still needs to approve."
        )
    }

    func testWebVTTStripsInlineTagsAndStylingClasses() {
        let raw = """
        WEBVTT

        00:00.000 --> 00:02.000
        <v.first Speaker One>Hello <00:00:01.000><c>there</c></v>
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(parsed.text, "Speaker One: Hello there")
        XCTAssertTrue(parsed.hasSpeakerLabels)
    }

    func testWebVTTCollapsesRollingCaptionDuplicates() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        Hello

        00:00:02.000 --> 00:00:04.000
        Hello

        00:00:04.000 --> 00:00:06.000
        Hello world
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(parsed.text, "Hello\nHello world")
    }

    func testWebVTTPreservesNumericOnlyCaptionText() {
        let raw = """
        WEBVTT

        1
        00:00:00.000 --> 00:00:02.000
        2027

        2
        00:00:02.000 --> 00:00:04.000
        Ship by Friday.
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(parsed.text, "2027\nShip by Friday.")
    }

    func testWebVTTPreservesCaptionTextWithLiteralArrow() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000
        Alice --> Bob owns the handoff.
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(parsed.text, "Alice --> Bob owns the handoff.")
    }

    func testWebVTTPreservesAngleBracketComparisons() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000
        Keep ARR < $5m and margin > 20%.
        """
        let parsed = TranscriptParser.parse(raw, format: .webVTT)
        XCTAssertEqual(parsed.text, "Keep ARR < $5m and margin > 20%.")
    }

    // MARK: - SubRip

    func testSubRipStripsIndicesAndTimestampsPreservingLabels() {
        let raw = """
        1
        00:00:00,000 --> 00:00:03,000
        Marcus: Let's review the numbers.

        2
        00:00:03,000 --> 00:00:06,000
        Dana: I'll send the deck by Friday.
        """
        let parsed = TranscriptParser.parse(raw, format: .subRip)
        XCTAssertEqual(
            parsed.text,
            "Marcus: Let's review the numbers.\nDana: I'll send the deck by Friday."
        )
        XCTAssertTrue(parsed.hasSpeakerLabels)
    }

    func testSubRipStripsFormattingTags() {
        let raw = """
        1
        00:00:00,000 --> 00:00:03,000
        <i>Marcus:</i> Let's <b>go</b>.
        """
        let parsed = TranscriptParser.parse(raw, format: .subRip)
        XCTAssertEqual(parsed.text, "Marcus: Let's go.")
    }

    func testSubRipMultiLineCueJoinsTextLines() {
        let raw = """
        1
        00:00:00,000 --> 00:00:04,000
        First line of the cue
        second line of the cue
        """
        let parsed = TranscriptParser.parse(raw, format: .subRip)
        XCTAssertEqual(parsed.text, "First line of the cue\nsecond line of the cue")
    }

    func testSubRipPreservesNumericOnlyCaptionText() {
        let raw = """
        1
        00:00:00,000 --> 00:00:03,000
        5000

        2
        00:00:03,000 --> 00:00:06,000
        Budget approved.
        """
        let parsed = TranscriptParser.parse(raw, format: .subRip)
        XCTAssertEqual(parsed.text, "5000\nBudget approved.")
    }

    func testSubRipPreservesCaptionTextWithLiteralArrow() {
        let raw = """
        1
        00:00:00,000 --> 00:00:03,000
        Alice --> Bob owns the handoff.
        """
        let parsed = TranscriptParser.parse(raw, format: .subRip)
        XCTAssertEqual(parsed.text, "Alice --> Bob owns the handoff.")
    }

    func testSubRipPreservesAngleBracketComparisons() {
        let raw = """
        1
        00:00:00,000 --> 00:00:03,000
        Keep ARR < $5m and margin > 20%.
        """
        let parsed = TranscriptParser.parse(raw, format: .subRip)
        XCTAssertEqual(parsed.text, "Keep ARR < $5m and margin > 20%.")
    }
}
