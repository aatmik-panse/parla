import Foundation

/// GitHub Releases update check. Pure version logic + a throttled fetch; the
/// menu wiring in main.swift stays thin. Fails silently on any error (network,
/// rate limit, no releases) — a convenience, never a nag or a crash.
public enum UpdateCheck {
    static let latestURL = URL(string: "https://api.github.com/repos/wannabeepolymath/parla/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/wannabeepolymath/parla/releases/latest")!
    static let throttleKey = "Parla.updateCheck.lastDate"

    /// The subset of the releases/latest payload we care about.
    struct Release: Decodable {
        let tagName: String
        let htmlURL: String?
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url" }
    }

    /// A newer release to point the user at.
    public struct Update: Sendable {
        public let version: String // display form, e.g. "v0.2.0"
        public let url: URL
    }

    /// Numeric, component-wise: "0.10.0" > "0.9.0", "0.1" == "0.1.0". A leading
    /// "v" is stripped; non-numeric components (prerelease garbage) parse as 0
    /// rather than crashing.
    static func components(_ version: String) -> [Int] {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return v.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// True when `remote` is a strictly newer version than `current`.
    public static func isNewer(remote: String, current: String) -> Bool {
        let a = components(remote), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Fetch the latest release and decide if it's newer than `currentVersion`.
    /// Throttled to once per 24h via UserDefaults; only a successful fetch
    /// stamps the timestamp. Returns nil when up-to-date, unbundled (no version),
    /// throttled, or on any failure.
    public static func check(currentVersion: String?,
                             defaults: UserDefaults = .standard,
                             now: Date = Date()) async -> Update? {
        guard let currentVersion else { return nil } // unbundled `swift run`: skip
        if let last = defaults.object(forKey: throttleKey) as? Date,
           now.timeIntervalSince(last) < 24 * 60 * 60 { return nil }
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        defaults.set(now, forKey: throttleKey)
        guard isNewer(remote: release.tagName, current: currentVersion) else { return nil }
        let display = "v" + (release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName)
        return Update(version: display, url: release.htmlURL.flatMap(URL.init(string:)) ?? releasesPage)
    }
}
