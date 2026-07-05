import Foundation

public struct Settings: Codable, Equatable {
    public var dictionary: [String] = []
    public var snippets: [String: String] = [:]
    public var cleanupModel: String = "claude-haiku-4-5"
    public var anthropicApiKey: String? = nil
    public var whisperModelPath: String? = nil
    public init() {}
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
