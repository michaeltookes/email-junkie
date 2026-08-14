import Foundation

/// A reusable summary of the user's writing voice, derived from their Sent mail
/// and injected into every draft-generation prompt (item 7).
struct VoiceProfile: Codable, Equatable {
    /// Typical opener, e.g. `"Hi {first name},"`.
    var greeting: String
    /// Typical closing, e.g. `"Best,\nMichael"`.
    var signOff: String
    /// Short descriptor of formality, e.g. `"casual but professional"`.
    var formality: String
    /// Short descriptor of tone, e.g. `"warm, direct"`.
    var tone: String
    /// Typical length, e.g. `"short — 2-4 sentences"`.
    var averageLength: String
    /// Recurring phrasings the user reaches for.
    var commonPhrases: [String]
    /// A human-readable paragraph shown in Settings.
    var summary: String
    /// How many Sent messages the profile was derived from.
    var sampleCount: Int
    /// When the profile was generated.
    var generatedAt: Date

    /// Renders the profile as instructions for injection into a draft prompt.
    func promptBlock() -> String {
        var lines = ["The reply must match the sender's writing voice:"]
        if !greeting.isEmpty { lines.append("- Greeting: \(greeting)") }
        if !signOff.isEmpty { lines.append("- Sign-off: \(signOff)") }
        if !formality.isEmpty { lines.append("- Formality: \(formality)") }
        if !tone.isEmpty { lines.append("- Tone: \(tone)") }
        if !averageLength.isEmpty { lines.append("- Typical length: \(averageLength)") }
        if !commonPhrases.isEmpty {
            lines.append("- Recurring phrases: \(commonPhrases.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }
}
