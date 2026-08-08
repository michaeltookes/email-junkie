import XCTest
@testable import EmailJunkie

/// Tests for the pure sender allow/blocklist evaluator (item 18). Matching and
/// precedence are load-bearing — a wrong verdict silently drafts blocked mail or
/// suppresses a wanted reply — so they are exercised exhaustively here with no IO.
final class SenderRulesTests: XCTestCase {

    private func rule(_ raw: String) -> SenderRule {
        guard let rule = SenderRule(rawInput: raw) else {
            fatalError("test rule input should be valid: \(raw)")
        }
        return rule
    }

    private func decide(
        _ sender: String?,
        allow: [String] = [],
        block: [String] = []
    ) -> SenderRuleDecision {
        SenderRules.decide(
            senderEmail: sender,
            allowlist: allow.map(rule),
            blocklist: block.map(rule)
        )
    }

    // MARK: - No opinion

    func testNoRulesIsNoOpinion() {
        XCTAssertEqual(decide("alice@example.com"), .noOpinion)
    }

    func testNilOrEmptySenderIsNoOpinion() {
        XCTAssertEqual(decide(nil, allow: ["alice@example.com"]), .noOpinion)
        XCTAssertEqual(decide("   ", block: ["example.com"]), .noOpinion)
    }

    func testUnrelatedRulesDoNotMatch() {
        XCTAssertEqual(decide("alice@example.com", allow: ["bob@other.com"], block: ["spam.net"]), .noOpinion)
    }

    // MARK: - Allowlist (force draft)

    func testAllowlistedAddressForcesDraft() {
        XCTAssertEqual(decide("alice@example.com", allow: ["alice@example.com"]), .forceDraft)
    }

    func testAllowlistedDomainForcesDraft() {
        XCTAssertEqual(decide("anyone@example.com", allow: ["example.com"]), .forceDraft)
    }

    func testAllowlistMatchIsCaseInsensitive() {
        XCTAssertEqual(decide("Alice@Example.COM", allow: ["alice@example.com"]), .forceDraft)
        XCTAssertEqual(decide("PERSON@Example.com", allow: ["EXAMPLE.com"]), .forceDraft)
    }

    // MARK: - Blocklist (skip)

    func testBlocklistedAddressBlocks() {
        XCTAssertEqual(decide("spammer@example.com", block: ["spammer@example.com"]), .block)
    }

    func testBlocklistedDomainBlocks() {
        XCTAssertEqual(decide("anyone@spam.net", block: ["spam.net"]), .block)
    }

    // MARK: - Domain matching discipline

    func testDomainRuleMatchesSubdomainOnDotBoundary() {
        XCTAssertEqual(decide("bounces@mail.example.com", block: ["example.com"]), .block)
    }

    func testDomainRuleDoesNotMatchLookAlikeDomain() {
        // "notexample.com" must not be caught by an "example.com" rule.
        XCTAssertEqual(decide("x@notexample.com", block: ["example.com"]), .noOpinion)
    }

    func testDomainRuleNeverMatchesLocalPart() {
        // "example.com" appearing in the local part must not trigger a domain match.
        XCTAssertEqual(decide("example.com@other.org", block: ["example.com"]), .noOpinion)
    }

    func testAddressRuleDoesNotMatchDifferentAddressSameDomain() {
        XCTAssertEqual(decide("bob@example.com", block: ["alice@example.com"]), .noOpinion)
    }

    // MARK: - Precedence (most specific wins; ties break to block)

    func testAddressAllowBeatsDomainBlock() {
        // A user blocks a whole domain but allowlists one person in it: the more
        // specific address allow wins so that person is still drafted.
        XCTAssertEqual(
            decide("vip@example.com", allow: ["vip@example.com"], block: ["example.com"]),
            .forceDraft
        )
    }

    func testAddressBlockBeatsDomainAllow() {
        // A user allowlists a whole domain but blocks one person in it: the more
        // specific address block wins so that person is skipped.
        XCTAssertEqual(
            decide("nuisance@example.com", allow: ["example.com"], block: ["nuisance@example.com"]),
            .block
        )
    }

    func testSameAddressOnBothListsBlockWins() {
        XCTAssertEqual(
            decide("who@example.com", allow: ["who@example.com"], block: ["who@example.com"]),
            .block
        )
    }

    func testSameDomainOnBothListsBlockWins() {
        XCTAssertEqual(
            decide("who@example.com", allow: ["example.com"], block: ["example.com"]),
            .block
        )
    }

    // MARK: - SenderRule normalization

    func testRuleNormalizesCaseAndWhitespace() {
        XCTAssertEqual(SenderRule(rawInput: "  Alice@Example.COM ")?.pattern, "alice@example.com")
        XCTAssertEqual(SenderRule(rawInput: "Alice@Example.COM")?.kind, .address)
    }

    func testLeadingAtSignBecomesDomainRule() {
        let rule = SenderRule(rawInput: "@Example.com")
        XCTAssertEqual(rule?.pattern, "example.com")
        XCTAssertEqual(rule?.kind, .domain)
    }

    func testBareTokenIsDomainRule() {
        XCTAssertEqual(SenderRule(rawInput: "example.com")?.kind, .domain)
    }

    func testInvalidInputsAreRejected() {
        XCTAssertNil(SenderRule(rawInput: ""))
        XCTAssertNil(SenderRule(rawInput: "   "))
        XCTAssertNil(SenderRule(rawInput: "@"))
        XCTAssertNil(SenderRule(rawInput: "foo@"))
        XCTAssertNil(SenderRule(rawInput: "foo@@example.com"))
        XCTAssertNil(SenderRule(rawInput: "foo@bar@example.com"))
        XCTAssertNil(SenderRule(rawInput: "@bar and baz"))
        XCTAssertNil(SenderRule(rawInput: "has space@example.com"))
    }

    // MARK: - Codable round trip

    func testSenderRuleCodableRoundTrip() throws {
        let rules = [rule("alice@example.com"), rule("example.com")]
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([SenderRule].self, from: data)
        XCTAssertEqual(decoded, rules)
    }
}
