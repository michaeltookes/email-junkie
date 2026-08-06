import Foundation

/// A single sender allow/blocklist entry (item 18). A rule matches either a full
/// email address (`alice@example.com`) or a whole domain (`example.com`); the
/// form is inferred from whether the normalized pattern contains an `@`.
///
/// Patterns are stored already normalized (trimmed + lowercased) so matching is
/// case-insensitive and persistence round-trips cleanly. `pattern` is the stable
/// identity, so the same entry can never appear twice on a list.
struct SenderRule: Codable, Equatable, Hashable, Identifiable {

    /// Whether the rule targets one exact address or a whole domain.
    enum Kind: Equatable { case address, domain }

    /// The normalized match pattern (lowercased, trimmed). Contains `@` for an
    /// address rule; otherwise it is a domain rule.
    let pattern: String

    var id: String { pattern }

    /// The inferred rule kind. Domain rules never contain `@`.
    var kind: Kind { pattern.contains("@") ? .address : .domain }

    /// Builds a rule from raw user input, or `nil` when the input can't form a
    /// usable rule. Normalizes case/whitespace and treats a leading `@` as a
    /// domain rule (`@example.com` → `example.com`). Address forms must have a
    /// non-empty local part and domain; nothing may contain interior whitespace.
    init?(rawInput: String) {
        var value = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("@") { value.removeFirst() }
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        if value.contains("@") {
            let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        }
        self.pattern = value
    }

    /// Wraps an already-normalized pattern (used by decoding and tests).
    init(normalized pattern: String) {
        self.pattern = pattern
    }

    /// A short label for the rule's form, for display and accessibility.
    var kindLabel: String {
        switch kind {
        case .address: return "Address"
        case .domain: return "Domain"
        }
    }
}
