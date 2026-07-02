import XCTest
@testable import EmailJunkie

final class PKCETests: XCTestCase {

    /// The canonical S256 test vector from RFC 7636, Appendix B.
    func testCodeChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(PKCEGenerator.codeChallenge(for: verifier), expected)
    }

    func testGeneratedPairHasS256MethodAndNonEmptyValues() {
        let pkce = PKCEGenerator.generate()
        XCTAssertEqual(pkce.method, "S256")
        XCTAssertFalse(pkce.verifier.isEmpty)
        XCTAssertFalse(pkce.challenge.isEmpty)
    }

    func testGeneratedChallengeMatchesItsVerifier() {
        let pkce = PKCEGenerator.generate()
        XCTAssertEqual(pkce.challenge, PKCEGenerator.codeChallenge(for: pkce.verifier))
    }

    func testGeneratedVerifiersAreUnique() {
        XCTAssertNotEqual(PKCEGenerator.generate().verifier, PKCEGenerator.generate().verifier)
    }

    func testBase64URLEncodingIsURLSafeAndUnpadded() {
        // 0xFB 0xFF encodes to "+/8=" in standard base64 → "-_8" in base64url.
        let encoded = Data([0xFB, 0xFF]).base64URLEncodedString()
        XCTAssertEqual(encoded, "-_8")
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }
}
