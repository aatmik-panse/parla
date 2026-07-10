import Foundation

public struct CleanupSettings: Codable, Equatable {
    public var provider: String = "anthropic"   // "anthropic" | "openai-compatible"
    public var baseURL: String? = nil            // required for openai-compatible
    public var model: String? = nil              // openai-compatible: required; anthropic: overrides cleanupModel
    public var apiKeyEnvVar: String? = nil       // name of env var holding the key
    public var apiKey: String? = nil             // inline fallback
    public init() {}

    // Tolerant decode: a partial cleanup block must not throw and reset all Settings.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? provider
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        apiKeyEnvVar = try c.decodeIfPresent(String.self, forKey: .apiKeyEnvVar) ?? apiKeyEnvVar
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
    }
}

public struct Settings: Codable, Equatable {
    public var dictionary: [String] = []
    public var snippets: [String: String] = [:]
    public var cleanupModel: String = "claude-haiku-4-5"
    public var anthropicApiKey: String? = nil
    public var whisperModelPath: String? = nil
    public var cleanup: CleanupSettings = CleanupSettings()
    // Local-only dictation history (menu paste-last / Recent). Never leaves the
    // machine; secure-field dictations are never recorded regardless.
    public var historyEnabled: Bool = true
    // Keep the dictation pill floating as a small idle capsule at all times,
    // morphing into the full pill during dictation. Off ⇒ transient toast only.
    public var showHudAlways: Bool = true
    // Idle bar size preset: "small" | "medium" | "large". Unknown values fall
    // back to small at the HUD layer.
    public var hudIdleSize: String = "small"
    // Mid-stream live retyping while fn is held. Off ⇒ instant raw finalize on
    // fn-up still happens; only the word-by-word revision stream is skipped.
    public var liveStreamingEnabled: Bool = true
    // Opt-in: put the clipboard back to what it held before dictating, once the
    // dictation is verified to have landed safely in a field (see Inserter.restore
    // call sites in AppDelegate.finish for the exact conditions).
    public var restoreClipboard: Bool = false
    // Core Audio UID of the input device to record from. nil ⇒ system default.
    // A UID that no longer resolves (device unplugged) also falls back to default.
    public var inputDeviceUID: String? = nil
    public init() {}

    // Tolerant decode: missing keys fall back to defaults so adding fields
    // never resets a user's settings.json. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? dictionary
        snippets = try c.decodeIfPresent([String: String].self, forKey: .snippets) ?? snippets
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel) ?? cleanupModel
        anthropicApiKey = try c.decodeIfPresent(String.self, forKey: .anthropicApiKey) ?? anthropicApiKey
        whisperModelPath = try c.decodeIfPresent(String.self, forKey: .whisperModelPath) ?? whisperModelPath
        cleanup = try c.decodeIfPresent(CleanupSettings.self, forKey: .cleanup) ?? cleanup
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? historyEnabled
        showHudAlways = try c.decodeIfPresent(Bool.self, forKey: .showHudAlways) ?? showHudAlways
        hudIdleSize = try c.decodeIfPresent(String.self, forKey: .hudIdleSize) ?? hudIdleSize
        liveStreamingEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveStreamingEnabled) ?? liveStreamingEnabled
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? restoreClipboard
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? inputDeviceUID
    }
}

public final class SettingsStore {
    public let url: URL
    /// Set by load() when settings.json exists but failed to parse. nil means
    /// either no file (fine, defaults) or the last load succeeded.
    public private(set) var lastError: String?

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/settings.json")
    }

    public func load() -> Settings {
        lastError = nil
        guard let data = try? Data(contentsOf: url) else { return Settings() } // no file: fine, defaults
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            lastError = Self.hint(error)
            return Settings()
        }
    }

    /// One-line, length-capped summary of a decode error — shown as a menu item
    /// title, so it must stay short even if DecodingError's description is huge.
    private static func hint(_ error: Error) -> String {
        let desc = String(describing: error)
        let line = desc.split(separator: "\n", maxSplits: 1).first ?? "unreadable settings.json"
        return String(line.prefix(200))
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: url, options: .atomic)
    }
}
