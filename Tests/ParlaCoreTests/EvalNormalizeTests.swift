import XCTest
import AVFoundation
@testable import ParlaCore

final class EvalNormalizeTests: XCTestCase {
    // Repro for the Int16-WAV read path: AVAudioFile.read(into:) throws at EOF
    // for this format instead of returning 0 frames; loadSamples must guard.
    func testLoadSamplesInt16Wav() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-load-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        // Write inside a scope so the AVAudioFile writer deallocs (flushes/closes)
        // before we read the file back.
        try {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let frames: AVAudioFrameCount = 3200 // 0.2s @ 16kHz
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            for i in 0..<Int(frames) {
                buf.floatChannelData![0][i] = sinf(2 * .pi * 440 * Float(i) / 16_000) * 0.5
            }
            try file.write(from: buf)
        }()

        let samples = try Eval.loadSamples(url: url)
        XCTAssert(abs(samples.count - 3200) <= 100, "got \(samples.count) samples")
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(Eval.normalize("  Hello,\n  world.  "), "Hello, world.")
    }
    func testCaseAndPunctuationPreserved() {
        XCTAssertEqual(Eval.normalize("Let's meet at 6."), "Let's meet at 6.")
        XCTAssertNotEqual(Eval.normalize("let's meet at 6"), "Let's meet at 6.")
    }
}
