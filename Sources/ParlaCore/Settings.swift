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
    }
}

public final class SettingsStore {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/settings.json")
    }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return s
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: url, options: .atomic)
    }
}
