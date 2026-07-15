import XCTest
@testable import ParlaCore

final class TextRulesTests: XCTestCase {
    // MARK: isTerminal
    func testKnownTerminalsMatch() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp",
                   "com.github.wez.wezterm", "net.kovidgoyal.kitty",
                   "com.mitchellh.ghostty", "org.alacritty", "co.zeit.hyper"] {
            XCTAssertTrue(TextRules.isTerminal(bundleID: id), id)
        }
    }

    func testNonTerminalAndNil() {
        XCTAssertFalse(TextRules.isTerminal(bundleID: "com.apple.Safari"))
        XCTAssertFalse(TextRules.isTerminal(bundleID: nil))
        XCTAssertFalse(TextRules.isTerminal(bundleID: ""))
    }

    func testFlattenNewlineTargets() {
        XCTAssertTrue(TextRules.flattensNewlines(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(TextRules.flattensNewlines(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(TextRules.flattensNewlines(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(TextRules.flattensNewlines(bundleID: nil))
    }

    // MARK: flattenForTerminal
    func testFlattenSingleNewline() {
        XCTAssertEqual(TextRules.flattenForTerminal("ls\nrm -rf /"), "ls rm -rf /")
    }

    func testFlattenCollapsesNewlineRunToOneSpace() {
        XCTAssertEqual(TextRules.flattenForTerminal("a\n\n\nb"), "a b")
        XCTAssertEqual(TextRules.flattenForTerminal("a  \n  b"), "a b")
    }

    func testFlattenTrims() {
        XCTAssertEqual(TextRules.flattenForTerminal("\n  hello world  \n"), "hello world")
    }

    func testFlattenLeavesNonNewlineSpacingAlone() {
        // A run of spaces with no newline is preserved (only leading/trailing trimmed).
        XCTAssertEqual(TextRules.flattenForTerminal("echo  hi"), "echo  hi")
    }

    func testFlattenSingleLineUnchanged() {
        XCTAssertEqual(TextRules.flattenForTerminal("git status"), "git status")
    }

    func testFlattenEmpty() {
        XCTAssertEqual(TextRules.flattenForTerminal(""), "")
        XCTAssertEqual(TextRules.flattenForTerminal("\n\n"), "")
    }

    // MARK: audioWorthTranscribing
    func testRejectsTooShort() {
        // 6399 samples (<0.4s) even at healthy loudness.
        XCTAssertFalse(TextRules.audioWorthTranscribing(sampleCount: 6399, rms: 0.1))
    }

    func testRejectsSilence() {
        // Plenty long, but near-digital-silence.
        XCTAssertFalse(TextRules.audioWorthTranscribing(sampleCount: 160_000, rms: 1e-5))
    }

    func testAcceptsRealSpeech() {
        XCTAssertTrue(TextRules.audioWorthTranscribing(sampleCount: 6400, rms: 1e-4))
        XCTAssertTrue(TextRules.audioWorthTranscribing(sampleCount: 32_000, rms: 0.05))
    }

    func testBoundaryExactlyAtFloor() {
        // Both thresholds are inclusive floors.
        XCTAssertTrue(TextRules.audioWorthTranscribing(sampleCount: 6400, rms: 1e-4))
        XCTAssertFalse(TextRules.audioWorthTranscribing(sampleCount: 6400, rms: 9e-5))
        XCTAssertFalse(TextRules.audioWorthTranscribing(sampleCount: 6399, rms: 1e-4))
    }
}
