import Foundation
import whisper

public struct TranscriberError: Error, CustomStringConvertible {
    public let description: String
}

public final class WhisperTranscriber {
    private let ctx: OpaquePointer

    public static func defaultModelPath() -> String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/models/ggml-base.en.bin").path
    }

    public init(modelPath: String) throws {
        // Metal GPU on by default — the v1.9.1 xcframework embeds the compiled Metal
        // library in the binary, so init no longer hits the old broken resource bundle.
        var params = whisper_context_default_params()
        params.flash_attn = true  // Metal flash attention (xcframework is v1.9.1) — off by default.
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw TranscriberError(description: "failed to load whisper model at \(modelPath)")
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// Whisper always encodes a full 30s window (1500 audio-ctx units, 320 samples each
    /// at 16kHz). Restricting the encoder to the clip's length is the big latency win for
    /// short dictations. Floor of 128 avoids quality collapse on tiny clips; +32 units
    /// (~0.64s) is a safety margin; 1500 is the model's trained ceiling.
    static func audioCtx(sampleCount: Int) -> Int32 {
        Int32(min(1500, max(128, sampleCount / 320 + 32)))
    }

    public func transcribe(_ samples: [Float], initialPrompt: String?, shouldAbort: (() -> Bool)? = nil) -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true
        params.temperature_inc = 0  // disable temperature-fallback re-decode → flat worst-case latency.
        // Default caps at min(4, cores); give the encode more threads, leaving headroom for the UI.
        params.n_threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.audio_ctx = Self.audioCtx(sampleCount: samples.count)

        // A C function pointer can't capture a Swift closure — pass the boxed closure through
        // abort_callback_user_data and unwrap it in the C-convention trampoline. Return true aborts.
        let abortBox = shouldAbort.map { AbortBox($0) }
        if let box = abortBox {
            params.abort_callback = { data in
                guard let data else { return false }
                return Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue().shouldAbort()
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        }

        let result: Int32 = withExtendedLifetime(abortBox) {
            samples.withUnsafeBufferPointer { buf in
                if let prompt = initialPrompt, !prompt.isEmpty {
                    // initial_prompt must stay alive through whisper_full → nested withCString.
                    return prompt.withCString { c in
                        params.initial_prompt = c
                        return whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                    }
                }
                return whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        guard result == 0 else { return "" }  // non-zero on error or cooperative abort.

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        return Self.stripNonSpeech(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whisper emits bracketed markers on non-speech audio — "[BLANK_AUDIO]",
    /// "[MUSIC]", "(silence)", "*sigh*" — which must never be typed or pasted.
    /// A transcript that is nothing but such markers becomes "".
    public static func stripNonSpeech(_ text: String) -> String {
        let wrapped = ["[": "]", "(": ")", "*": "*"]
        let isMarker = { (word: Substring) -> Bool in
            guard let first = word.first, let close = wrapped[String(first)] else { return false }
            return word.hasSuffix(close) && word.count > 1
        }
        return text.split(separator: " ").allSatisfy(isMarker) ? "" : text
    }
}

/// Reference box so a Swift abort closure survives the trip through whisper's
/// C `void *` user-data pointer.
private final class AbortBox {
    let shouldAbort: () -> Bool
    init(_ shouldAbort: @escaping () -> Bool) { self.shouldAbort = shouldAbort }
}
