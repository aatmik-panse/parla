import XCTest
@testable import ParlaCore

final class TranscriberTests: XCTestCase {
    func testTranscribeSilenceProducesNoCrash() throws {
        let path = WhisperTranscriber.defaultModelPath()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "no whisper model — run scripts/download-model.sh")
        let t = try WhisperTranscriber(modelPath: path)
        // 1s of silence: must not crash; output may be empty or hallucinated punctuation.
        let out = t.transcribe([Float](repeating: 0, count: 16_000), initialPrompt: "Kubernetes")
        XCTAssertNotNil(out)
    }

    func testMissingModelThrows() {
        XCTAssertThrowsError(try WhisperTranscriber(modelPath: "/nonexistent.bin"))
    }

    func testAudioCtxScaling() {
        // Floor: tiny clips clamp to 128.
        XCTAssertEqual(WhisperTranscriber.audioCtx(sampleCount: 0), 128)
        XCTAssertEqual(WhisperTranscriber.audioCtx(sampleCount: 16_000), 128)  // 1s → 82, floored.
        // Linear in the middle: 3s = 48000 samples → 48000/320 + 32 = 182.
        XCTAssertEqual(WhisperTranscriber.audioCtx(sampleCount: 48_000), 182)
        // Ceiling: full 30s window and beyond clamp to 1500.
        XCTAssertEqual(WhisperTranscriber.audioCtx(sampleCount: 480_000), 1500)
        XCTAssertEqual(WhisperTranscriber.audioCtx(sampleCount: 1_000_000), 1500)
    }

    func testBlankAudioMarkerStripped() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("(silence)"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("*sigh*"), "")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("[MUSIC] [BLANK_AUDIO]"), "")
    }

    func testRealSpeechUntouched() {
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Hello world."), "Hello world.")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech("Array [0] is empty"), "Array [0] is empty")
        XCTAssertEqual(WhisperTranscriber.stripNonSpeech(""), "")
    }
}
