import XCTest
@testable import parrot

/// The matcher's contract, written as the cases that drove its design.
final class PhoneticMatcherTests: XCTestCase {
    private let terms = [
        "PostHog", "Tailwind", "Kubernetes", "TypeScript", "GitHub", "Xcode",
        "ClickHouse", "WhisperKit", "Postgres", "Figma", "Anthropic", "CORS",
        "SwiftUI", "Deelr", "Supabase", "Claude",
    ]
    /// Ordinary words that collide phonetically with terms above.
    private let ordinary = FixedWordList([
        "dealer", "dollar", "core", "cores", "call", "called", "swift",
        "post", "hog", "auto", "the", "car", "this", "morning", "are", "hot",
    ])

    private func matcher(rules: [Vocabulary.Replacement] = []) -> PhoneticMatcher {
        PhoneticMatcher(terms: terms, rules: rules, wordList: ordinary)
    }

    private func rule(_ from: String, _ to: String, fuzzy: Bool = false) -> Vocabulary.Replacement {
        Vocabulary.Replacement(from: from, to: to, fuzzy: fuzzy)
    }

    // MARK: - What it should fix

    func testRewritesMishearingsOfTerms() {
        let cases = [
            "post hog": "PostHog",
            "post hawk": "PostHog",
            "post hogg": "PostHog",
            "tail wind": "Tailwind",
            "kuber netes": "Kubernetes",
            "type script": "TypeScript",
            "git hub": "GitHub",
            "click house": "ClickHouse",
            "whisper kit": "WhisperKit",
            "post gress": "Postgres",
            "anthropik": "Anthropic",
            "figmuh": "Figma",
            "ex code": "Xcode",
        ]
        for (heard, want) in cases {
            XCTAssertEqual(matcher().apply(to: heard), want, "heard: \(heard)")
        }
    }

    func testRewritesInsideASentence() {
        XCTAssertEqual(
            matcher().apply(to: "check the post hawk dashboard"),
            "check the PostHog dashboard"
        )
    }

    func testLeavesAlreadyCorrectTextAlone() {
        XCTAssertEqual(matcher().apply(to: "PostHog is fine"), "PostHog is fine")
    }

    func testPreservesTrailingPossessive() {
        XCTAssertEqual(matcher().apply(to: "post hog's dashboard"), "PostHog's dashboard")
    }

    func testPreservesSurroundingQuotes() {
        XCTAssertEqual(matcher().apply(to: "check 'post hawk' first"), "check 'PostHog' first")
    }

    // MARK: - What it must never break

    /// Phonetic keys are lossy: dealer, dollar and Deelr all encode to TLR.
    func testNeverRewritesAnOrdinaryEnglishWord() {
        let untouched = [
            "I called the car dealer this morning",
            "the cores are hot",
            "she gave a swift response",
        ]
        for sentence in untouched {
            XCTAssertEqual(matcher().apply(to: sentence), sentence)
        }
    }

    func testDoesNotMatchAcrossSentencePunctuation() {
        XCTAssertEqual(matcher().apply(to: "send the post. Hog farming is next"),
                       "send the post. Hog farming is next")
    }

    func testIgnoresFragmentsOfAlphanumericRuns() {
        XCTAssertEqual(matcher().apply(to: "verify the ch8256"), "verify the ch8256")
    }

    func testIgnoresNonLatinText() {
        let russian = "Привет, как дела?"
        XCTAssertEqual(matcher().apply(to: russian), russian)
    }

    func testShortTermsAreNotMatchedPhonetically() {
        let noGuard = PhoneticMatcher(terms: ["CORS"], wordList: FixedWordList([]))
        XCTAssertEqual(noGuard.apply(to: "kores"), "kores")
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(matcher().apply(to: ""), "")
        XCTAssertEqual(matcher().apply(to: "   "), "   ")
    }

    // MARK: - Window selection

    func testLongerPhraseWinsOverItsFirstWord() {
        XCTAssertEqual(matcher().apply(to: "swift UI"), "SwiftUI")
    }

    // MARK: - Rules

    func testExactRuleMatchesBySoundNotJustSpelling() {
        let m = matcher(rules: [rule("super base", "Supabase")])
        XCTAssertEqual(m.apply(to: "Superbass"), "Supabase")
        XCTAssertEqual(m.apply(to: "Superbase"), "Supabase")
    }

    func testExactRuleDoesNotTolerateAnExtraSound() {
        let m = matcher(rules: [rule("v auto", "vAuto")])
        XCTAssertEqual(m.apply(to: "V alto"), "V alto")
    }

    func testFuzzyRuleAllowsOneSoundOfSlack() {
        let m = matcher(rules: [rule("v auto", "vAuto", fuzzy: true)])
        XCTAssertEqual(m.apply(to: "V alto"), "vAuto")
        XCTAssertEqual(m.apply(to: "V Auto"), "vAuto")
    }

    /// A fuzzy rule waives the ordinary-word guard only for its own wording.
    func testFuzzyRuleStillProtectsOtherOrdinaryWords() {
        let m = matcher(rules: [rule("v auto", "vAuto", fuzzy: true)])
        XCTAssertEqual(m.apply(to: "my auto loan"), "my auto loan")
        XCTAssertEqual(m.apply(to: "the auto industry"), "the auto industry")
    }

    func testRuleRewritesTheExactOrdinaryWordItDeclares() {
        let m = matcher(rules: [rule("dealer", "Deelr", fuzzy: true)])
        XCTAssertEqual(m.apply(to: "dealer"), "Deelr")
    }

    func testRuleDoesNotReachAnUnrelatedOrdinaryWord() {
        let m = matcher(rules: [rule("deal er", "Deelr", fuzzy: true)])
        XCTAssertEqual(m.apply(to: "that costs a dollar"), "that costs a dollar")
    }

    func testRulesBeatTermsWhenBothCouldMatch() {
        let m = matcher(rules: [rule("post hog", "PostHog Cloud")])
        XCTAssertEqual(m.apply(to: "post hog"), "PostHog Cloud")
    }

    // MARK: - Reported detail

    func testMatchReportsWhatFiredAndWhy() {
        let m = matcher(rules: [rule("super base", "Supabase")])
        let matches = m.matches(in: "post hawk and Superbass")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].term, "PostHog")
        XCTAssertNil(matches[0].rule, "a term match has no rule")
        XCTAssertEqual(matches[1].term, "Supabase")
        XCTAssertEqual(matches[1].rule, "super base")
        XCTAssertGreaterThanOrEqual(matches[1].similarity, PhoneticMatcher.similarityFloor)
    }

    func testMatchesAreReportedInReadingOrder() {
        let matches = matcher().matches(in: "tail wind then git hub")
        XCTAssertEqual(matches.map(\.term), ["Tailwind", "GitHub"])
    }
}

final class EditDistanceTests: XCTestCase {
    func testIdenticalAndEmpty() {
        XCTAssertEqual(PhoneticMatcher.editDistance("PSTHK", "PSTHK"), 0)
        XCTAssertEqual(PhoneticMatcher.editDistance("", ""), 0)
        XCTAssertEqual(PhoneticMatcher.editDistance("ABC", ""), 3)
    }

    func testSingleEdits() {
        XCTAssertEqual(PhoneticMatcher.editDistance("PSTHK", "PSTHL"), 1)  // substitute
        XCTAssertEqual(PhoneticMatcher.editDistance("SPBS", "SPRBS"), 1)   // insert
        XCTAssertEqual(PhoneticMatcher.editDistance("FALT", "FAT"), 1)     // delete
    }

    func testDistantKeys() {
        XCTAssertEqual(PhoneticMatcher.editDistance("0A0R", "FAT"), 3)
    }
}
