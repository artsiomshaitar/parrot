import XCTest
@testable import parrot

final class MetaphoneTests: XCTestCase {
    func testEncodesCommonWords() {
        XCTAssertEqual(Metaphone.encode("post"), "PST")
        XCTAssertEqual(Metaphone.encode("hog"), "HK")
        XCTAssertEqual(Metaphone.encode("hawk"), "HK")
        XCTAssertEqual(Metaphone.encode("tail"), "TL")
        XCTAssertEqual(Metaphone.encode("wind"), "WNT")
    }

    /// The point of the whole feature: spellings that sound alike collapse.
    func testMishearingsCollapseToTheSameKey() {
        XCTAssertEqual(Metaphone.encode("hog"), Metaphone.encode("hawk"))
        XCTAssertEqual(Metaphone.encode("gres"), Metaphone.encode("gress"))
    }

    func testSilentInitialClusters() {
        XCTAssertEqual(Metaphone.encode("knee"), "N")
        XCTAssertEqual(Metaphone.encode("gnome"), "NM")
        XCTAssertEqual(Metaphone.encode("write"), "RT")
        XCTAssertEqual(Metaphone.encode("pneumatic"), "NMTK")
    }

    func testWordInitialXBecomesS() {
        XCTAssertEqual(Metaphone.encode("Xcode"), "SKT")
        XCTAssertEqual(Metaphone.encode("ex"), "EKS")
    }

    func testDigraphs() {
        XCTAssertEqual(Metaphone.encode("phone"), "FN")
        XCTAssertEqual(Metaphone.encode("thing"), "0NK")
        XCTAssertEqual(Metaphone.encode("ship"), "XP")
    }

    func testVowelsKeptOnlyAtTheStart() {
        XCTAssertEqual(Metaphone.encode("audio"), "AT")
        XCTAssertEqual(Metaphone.encode("radio"), "RT")
    }

    func testDoubledLettersSoundOnce() {
        XCTAssertEqual(Metaphone.encode("hogg"), Metaphone.encode("hog"))
    }

    func testIgnoresNonLettersAndCase() {
        XCTAssertEqual(Metaphone.encode("PoSt"), Metaphone.encode("post"))
        XCTAssertEqual(Metaphone.encode("p-o-s-t"), Metaphone.encode("post"))
    }

    func testEmptyInput() {
        XCTAssertEqual(Metaphone.encode(""), "")
        XCTAssertEqual(Metaphone.encode("123"), "")
    }
}

final class SimilarityTests: XCTestCase {
    func testIdenticalStringsScoreOne() {
        XCTAssertEqual(Similarity.jaroWinkler("posthog", "posthog"), 1.0, accuracy: 0.0001)
    }

    func testEmptyStrings() {
        XCTAssertEqual(Similarity.jaroWinkler("", ""), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Similarity.jaroWinkler("a", ""), 0.0, accuracy: 0.0001)
    }

    func testKnownValue() {
        XCTAssertEqual(Similarity.jaroWinkler("posthawk", "posthog"), 0.8679, accuracy: 0.001)
    }

    func testSharedPrefixScoresHigherThanSharedSuffix() {
        let prefix = Similarity.jaroWinkler("postxxx", "postyyy")
        let suffix = Similarity.jaroWinkler("xxxpost", "yyypost")
        XCTAssertGreaterThan(prefix, suffix)
    }

    func testUnrelatedStringsScoreLow() {
        XCTAssertLessThan(Similarity.jaroWinkler("kubernetes", "figma"), 0.6)
    }

    func testSymmetry() {
        XCTAssertEqual(
            Similarity.jaroWinkler("superbass", "supabase"),
            Similarity.jaroWinkler("supabase", "superbass"),
            accuracy: 0.0001
        )
    }
}

final class PhoneticKeyTests: XCTestCase {
    func testSplitsOnCamelCase() {
        XCTAssertEqual(PhoneticKey.words(in: "PostHog"), ["Post", "Hog"])
        XCTAssertEqual(PhoneticKey.words(in: "WhisperKit"), ["Whisper", "Kit"])
    }

    func testSplitsOnSeparators() {
        XCTAssertEqual(PhoneticKey.words(in: "React Native"), ["React", "Native"])
        XCTAssertEqual(PhoneticKey.words(in: "Node.js"), ["Node", "js"])
        XCTAssertEqual(PhoneticKey.words(in: "post-hog"), ["post", "hog"])
    }

    func testConsecutiveCapitalsStayTogether() {
        XCTAssertEqual(PhoneticKey.words(in: "GraphQL"), ["Graph", "QL"])
    }

    /// The split key is what lets a spoken "post hog" reach the written
    func testTermIsReachableBySpokenForm() {
        let spoken = PhoneticKey.of(words: ["post", "hog"])
        XCTAssertTrue(PhoneticKey.variants(of: "PostHog").contains(spoken))
    }

    func testWholeWordKeyIsAlsoOffered() {
        XCTAssertTrue(PhoneticKey.variants(of: "PostHog").contains(Metaphone.encode("posthog")))
    }

    func testXInitialTermsGetASpelledOutKey() {
        XCTAssertTrue(PhoneticKey.variants(of: "Xcode").contains(PhoneticKey.of(words: ["ex", "code"])))
    }

    func testComparableStripsNonLetters() {
        XCTAssertEqual(PhoneticKey.comparable("Node.js"), "nodejs")
        XCTAssertEqual(PhoneticKey.comparable("C++"), "c")
    }
}
