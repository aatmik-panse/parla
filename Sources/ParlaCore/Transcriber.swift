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
        // Not mutated → let (avoids "never mutated" warning). Metal/GPU is on by default.
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
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
