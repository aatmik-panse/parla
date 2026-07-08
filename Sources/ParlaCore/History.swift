import Foundation

/// One recorded dictation. `cleaned` is nil when cleanup failed, was skipped
/// (secure field), or produced text identical to `raw`. Codable Date rides the
/// default JSONEncoder representation — roundtrips with the matching decoder.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var raw: String
    public var cleaned: String?
    public var appName: String?
    public init(date: Date = Date(), raw: String, cleaned: String? = nil, appName: String? = nil) {
        self.date = date; self.raw = raw; self.cleaned = cleaned; self.appName = appName
    }
    /// What to paste/show: the polished text when we have it, else the raw.
    public var best: String { cleaned ?? raw }
}

/// Local-only dictation log at ~/Library/Application Support/Parla/history.json.
/// Newest-first ring buffer, oldest dropped past the cap. Same save style as
/// SettingsStore. ponytail: no index, no async — a 50-entry array is nothing.
public final class HistoryStore {
    public static let cap = 50 // ponytail: bump if users want a deeper log
    public let url: URL
    private var items: [HistoryEntry] // oldest first internally

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/history.json")
        items = (try? Data(contentsOf: self.url))
            .flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    /// Newest first.
    public var entries: [HistoryEntry] { items.reversed() }

    public func append(_ entry: HistoryEntry) {
        items.append(entry)
        if items.count > Self.cap { items.removeFirst(items.count - Self.cap) }
        save()
    }

    public func clear() {
        items = []
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(items).write(to: url, options: .atomic)
    }
}
