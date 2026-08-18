import XCTest
@testable import parrot

final class VocabularySummaryTests: XCTestCase {
    func testEmptyVocabulary() {
        XCTAssertEqual(VocabularyStore.summary(of: nil), "empty")
        XCTAssertEqual(VocabularyStore.summary(of: Vocabulary.parse("")), "empty")
    }

    func testTermsOnly() {
        XCTAssertEqual(VocabularyStore.summary(of: Vocabulary.parse("PostHog\nFigma")), "2 terms")
    }

    func testSingularIsNotPluralised() {
        XCTAssertEqual(VocabularyStore.summary(of: Vocabulary.parse("PostHog")), "1 term")
    }

    func testTermsAndRules() {
        let vocab = Vocabulary.parse("PostHog\nmy sequel => MySQL")
        XCTAssertEqual(VocabularyStore.summary(of: vocab), "2 terms, 1 rule")
    }
}

final class DeviceSnapshotTests: XCTestCase {
    private func snapshot(rate: Double) -> InputDeviceMonitor.Snapshot {
        InputDeviceMonitor.Snapshot(isRunning: true, outputSampleRate: rate)
    }

    func testCallModeIsDetectedByLowSampleRate() {
        XCTAssertTrue(snapshot(rate: 16_000).isCallMode)
        XCTAssertTrue(snapshot(rate: 8_000).isCallMode)
    }

    func testMusicCodecIsNotCallMode() {
        XCTAssertFalse(snapshot(rate: 44_100).isCallMode)
        XCTAssertFalse(snapshot(rate: 48_000).isCallMode)
    }

    /// An unreadable device reports zero, which is not "call mode".
    func testUnknownRateIsNotCallMode() {
        XCTAssertFalse(snapshot(rate: 0).isCallMode)
    }
}

final class AppIdentityTests: XCTestCase {
    func testVocabularyIsSharedAcrossProfiles() {
        XCTAssertTrue(Vocabulary.defaultPath.hasPrefix(AppIdentity.sharedConfigDirectory))
    }

    func testConfigIsPerProfile() {
        XCTAssertTrue(Config.path.hasPrefix(AppIdentity.configDirectory))
    }

    func testLaunchAgentLabelIsPerProfile() {
        XCTAssertTrue(AppIdentity.launchAgentLabel.hasSuffix(AppIdentity.profile))
    }
}
