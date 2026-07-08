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
        let params = whisper_context_default_params()
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw TranscriberError(description: "failed to load whisper model at \(modelPath)")
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    public func transcribe(_ samples: [Float], initialPrompt: String?) -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true

        let result: Int32 = samples.withUnsafeBufferPointer { buf in
            if let prompt = initialPrompt, !prompt.isEmpty {
                // initial_prompt must stay alive through whisper_full → nested withCString.
                return prompt.withCString { c in
                    params.initial_prompt = c
                    return whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
            return whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard result == 0 else { return "" }

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
