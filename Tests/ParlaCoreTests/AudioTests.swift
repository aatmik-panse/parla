import XCTest
import AVFoundation
@testable import ParlaCore

final class AudioTests: XCTestCase {
    /// 0.5s 440Hz sine at 48kHz stereo → expect ~8000 mono samples at 16kHz.
    func testConvertResamplesTo16kMono() throws {
        let srcFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames: AVAudioFrameCount = 24_000
        let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let ptr = buf.floatChannelData![ch]
            for i in 0..<Int(frames) {
                ptr[i] = sinf(2 * .pi * 440 * Float(i) / 48_000)
            }
        }
        let out = AudioRecorder.convert(buf)
        XCTAssertEqual(out.count, 8_000, accuracy: 200)
        XCTAssertGreaterThan(out.map(abs).max() ?? 0, 0.5) // signal survived
    }

    func testConvertPassthroughAt16kMono() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600)!
        buf.frameLength = 1600
        XCTAssertEqual(AudioRecorder.convert(buf).count, 1600, accuracy: 50)
    }
}

func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy,
        "\(a) not within \(accuracy) of \(b)", file: file, line: line)
}
