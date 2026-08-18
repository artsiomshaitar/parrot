import XCTest
@testable import parrot

final class VocabularyParsingTests: XCTestCase {
    func testParsesTermsOnePerLine() {
        let vocab = Vocabulary.parse("PostHog\nKubernetes\n")
        XCTAssertEqual(vocab.terms, ["PostHog", "Kubernetes"])
        XCTAssertTrue(vocab.replacements.isEmpty)
    }

    func testIgnoresCommentsAndBlankLines() {
        let vocab = Vocabulary.parse("""
        # a comment
        PostHog

           # indented comment
        Figma
        """)
        XCTAssertEqual(vocab.terms, ["PostHog", "Figma"])
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(Vocabulary.parse("   PostHog   \n").terms, ["PostHog"])
    }

    func testDropsDuplicateTermsCaseInsensitively() {
        XCTAssertEqual(Vocabulary.parse("PostHog\nposthog\nPOSTHOG").terms, ["PostHog"])
    }

    func testParsesExactRules() {
        let vocab = Vocabulary.parse("my sequel => MySQL")
        XCTAssertEqual(vocab.replacements.count, 1)
        XCTAssertEqual(vocab.replacements[0].from, "my sequel")
        XCTAssertEqual(vocab.replacements[0].to, "MySQL")
        XCTAssertFalse(vocab.replacements[0].fuzzy)
    }

    func testParsesFuzzyRules() {
        let vocab = Vocabulary.parse("v auto ~> vAuto")
        XCTAssertEqual(vocab.replacements.count, 1)
        XCTAssertTrue(vocab.replacements[0].fuzzy)
        XCTAssertEqual(vocab.replacements[0].to, "vAuto")
    }

    /// A rule's target is worth matching by sound in its own right.
    func testRuleTargetBecomesATerm() {
        XCTAssertEqual(Vocabulary.parse("my sequel => MySQL").terms, ["MySQL"])
    }

    func testIgnoresRulesWithNoLeftSide() {
        XCTAssertTrue(Vocabulary.parse("=> MySQL").replacements.isEmpty)
    }

    func testEmptyFileIsEmpty() {
        XCTAssertTrue(Vocabulary.parse("").isEmpty)
        XCTAssertTrue(Vocabulary.parse("# only comments\n").isEmpty)
    }
}

final class VocabularyApplyTests: XCTestCase {
    func testExactRuleIsCaseInsensitive() {
        let vocab = Vocabulary.parse("my sequel => MySQL")
        XCTAssertEqual(vocab.applyReplacements(to: "use my sequel here"), "use MySQL here")
        XCTAssertEqual(vocab.applyReplacements(to: "use My Sequel here"), "use MySQL here")
    }

    func testLongerRuleWinsOverAShorterOne() {
        let vocab = Vocabulary.parse("""
        post hog cloud => PostHog Cloud
        post hog => PostHog
        """)
        XCTAssertEqual(vocab.applyReplacements(to: "the post hog cloud plan"), "the PostHog Cloud plan")
    }

    func testRuleDoesNotMatchInsideALongerWord() {
        let vocab = Vocabulary.parse("hog => PostHog")
        XCTAssertEqual(vocab.applyReplacements(to: "hogwash"), "hogwash")
    }

    func testApplyRunsRulesThenPhonetics() {
        let vocab = Vocabulary.parse("PostHog\nmy sequel => MySQL")
        XCTAssertEqual(vocab.apply(to: "my sequel and post hawk"), "MySQL and PostHog")
    }

    func testApplyLeavesUnrelatedTextAlone() {
        let vocab = Vocabulary.parse("PostHog")
        XCTAssertEqual(vocab.apply(to: "nothing to see"), "nothing to see")
    }
}

final class TranscriptSanitizerTests: XCTestCase {
    func testStripsNonSpeechTokens() {
        XCTAssertEqual(WhisperKitTranscriber.sanitize("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("hello [MUSIC] world"), "hello world")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("(silence) hi"), "hi")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("<|nospeech|>hi"), "hi")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("*cough* hi"), "hi")
    }

    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(WhisperKitTranscriber.sanitize("  hello   world  "), "hello world")
    }

    func testLeavesOrdinaryTextIntact() {
        XCTAssertEqual(WhisperKitTranscriber.sanitize("Let's meet at 3."), "Let's meet at 3.")
    }
}

final class HotkeyTests: XCTestCase {
    func testParsesEveryNamedKey() {
        for key in MenuBarController.selectableHotkeys {
            XCTAssertEqual(Hotkey(name: key.label), key, "round trip failed for \(key.label)")
        }
    }

    func testRejectsUnknownNames() {
        XCTAssertNil(Hotkey(name: "banana"))
        XCTAssertNil(Hotkey(name: ""))
    }

    func testModifierKeysCarryAKeycodeExceptFn() {
        XCTAssertNil(Hotkey.fn.keyCode)
        XCTAssertEqual(Hotkey.rightCommand.keyCode, 54)
    }
}
