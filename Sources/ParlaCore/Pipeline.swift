import Foundation

public struct Pipeline {
    public var transcribe: ([Float], String?) -> String
    public var cleanup: (String, CleanupContext) async throws -> String
    public var settings: () -> Settings
    public var frontAppName: () -> String?

    public init(transcribe: @escaping ([Float], String?) -> String,
                cleanup: @escaping (String, CleanupContext) async throws -> String,
                settings: @escaping () -> Settings,
                frontAppName: @escaping () -> String?) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.settings = settings
        self.frontAppName = frontAppName
    }

    /// Whisper pass only: trimmed transcript, nil when empty. Split from clean()
    /// so the caller can finalize raw text instantly and polish behind it.
    public func transcript(samples: [Float]) -> String? {
        let s = settings()
        let prompt = s.dictionary.isEmpty ? nil : s.dictionary.joined(separator: ", ")
        let t = transcribe(samples, prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// LLM cleanup, sanitized. Never throws — cleanup must never kill a
    /// dictation, so failures hand back the raw transcript.
    public func clean(transcript: String) async -> String {
        let s = settings()
        let ctx = CleanupContext(dictionary: s.dictionary, snippets: s.snippets,
                                 appName: frontAppName())
        do {
            return CleanupSanitizer.sanitize(try await cleanup(transcript, ctx))
        } catch {
            NSLog("Parla cleanup failed, keeping raw transcript: \(error)")
            return transcript
        }
    }

    public func process(samples: [Float]) async -> String? {
        guard let t = transcript(samples: samples) else { return nil }
        return await clean(transcript: t)
    }
}
