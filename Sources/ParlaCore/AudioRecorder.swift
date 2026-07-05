import AVFoundation

public final class AudioRecorder {
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Called with each converted buffer's RMS level. Fires on the audio
    /// thread — callers must hop to main before touching UI.
    public var onLevel: ((Float) -> Void)?

    public init() {}

    /// Root-mean-square amplitude of samples; 0 for empty input.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSq / Float(samples.count)).squareRoot()
    }

    /// Convert any PCM buffer to 16kHz mono Float32 samples.
    public static func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if buffer.format == targetFormat {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                             count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        else { return [] }
        let ratio = 16_000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return [] }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            // endOfStream (not noDataNow) so the converter drains the resampler's
            // tail latency; each buffer is a complete unit (fresh converter per call).
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0],
                                         count: Int(out.frameLength)))
    }

    public func start() throws {
        samples.removeAll()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let chunk = AudioRecorder.convert(buf)
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            self.lock.unlock()
            self.onLevel?(AudioRecorder.rms(chunk))
        }
        try engine.start()
    }

    /// Copy of the samples captured so far, under the lock. Safe to call
    /// mid-recording (the streaming loop polls this).
    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
