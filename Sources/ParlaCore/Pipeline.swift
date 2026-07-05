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

    public func process(samples: [Float]) async -> String? {
        let s = settings()
        let prompt = s.dictionary.isEmpty ? nil : s.dictionary.joined(separator: ", ")
        let transcript = transcribe(samples, prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }
        let ctx = CleanupContext(dictionary: s.dictionary, snippets: s.snippets,
                                 appName: frontAppName())
        do {
            return CleanupSanitizer.sanitize(try await cleanup(transcript, ctx))
        } catch {
            // Cleanup must never kill a dictation — hand back the raw transcript.
            NSLog("Parla cleanup failed, inserting raw transcript: \(error)")
            return transcript
        }
    }
}
