import Foundation
import AVFoundation

public enum Eval {
    public static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        var all: [Float] = []
        let format = file.processingFormat
        // Guard EOF before reading: for some formats (e.g. Int16 WAV) read(into:)
        // at EOF throws (nilError) instead of returning 0 frames.
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            all.append(contentsOf: AudioRecorder.convert(buf))
        }
        return all
    }
}
