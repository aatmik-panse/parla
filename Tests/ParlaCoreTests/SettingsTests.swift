import XCTest
@testable import ParlaCore

final class SettingsTests: XCTestCase {
    func tempStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsStore(url: dir.appendingPathComponent("settings.json"))
    }

    func testDefaultsWhenFileMissing() {
        let store = tempStore()
        let s = store.load()
        XCTAssertEqual(s.cleanupModel, "claude-haiku-4-5")
        XCTAssertTrue(s.dictionary.isEmpty)
        XCTAssertTrue(s.snippets.isEmpty)
        XCTAssertNil(store.lastError) // missing file is fine, not an error
    }

    func testRoundTrip() throws {
        let store = tempStore()
        var s = Settings()
        s.dictionary = ["Kubernetes", "Daksh"]
        s.snippets = ["insert my calendar link": "https://cal.com/daksh"]
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        XCTAssertNil(store.lastError)
    }

    func testCorruptFileFallsBackToDefaultsAndReportsError() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.lastError!.contains("\n")) // trimmed to one line for menu display
    }

    func testErrorClearsOnNextGoodLoad() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        _ = store.load()
        XCTAssertNotNil(store.lastError)
        try store.save(Settings())
        _ = store.load()
        XCTAssertNil(store.lastError)
    }

    func testPartialFileDecodesWithDefaults() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"dictionary":["Kubernetes"]}"#.utf8).write(to: store.url)
        let s = store.load()
        XCTAssertEqual(s.dictionary, ["Kubernetes"])
        XCTAssertEqual(s.cleanupModel, "claude-haiku-4-5")   // default survives
        XCTAssertEqual(s.cleanup, CleanupSettings())          // default block
    }

    func testUnknownKeysIgnored() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"futureField":true,"cleanupModel":"m"}"#.utf8).write(to: store.url)
        XCTAssertEqual(store.load().cleanupModel, "m")
    }

    func testPartialCleanupBlockDecodesWithDefaults() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cleanup":{"model":"m"},"dictionary":["X"]}"#.utf8).write(to: store.url)
        let s = store.load()
        XCTAssertEqual(s.cleanup.provider, "anthropic")
        XCTAssertEqual(s.cleanup.model, "m")
        XCTAssertEqual(s.dictionary, ["X"])
    }

    func testLiveStreamingEnabledDefaultTrue() {
        XCTAssertTrue(Settings().liveStreamingEnabled)
    }

    func testLiveStreamingEnabledTolerantDecode() throws {
        let missing = try JSONDecoder().decode(Settings.self, from: Data(#"{"dictionary":["X"]}"#.utf8))
        XCTAssertTrue(missing.liveStreamingEnabled)
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"liveStreamingEnabled":false}"#.utf8))
        XCTAssertFalse(off.liveStreamingEnabled)
    }

    func testRestoreClipboardDefaultFalse() {
        XCTAssertFalse(Settings().restoreClipboard)
    }

    func testRestoreClipboardTolerantDecode() throws {
        let missing = try JSONDecoder().decode(Settings.self, from: Data(#"{"dictionary":["X"]}"#.utf8))
        XCTAssertFalse(missing.restoreClipboard)
        let on = try JSONDecoder().decode(Settings.self, from: Data(#"{"restoreClipboard":true}"#.utf8))
        XCTAssertTrue(on.restoreClipboard)
    }

    func testCleanupBlockRoundTrip() throws {
        let store = tempStore()
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "https://api.groq.com/openai/v1"
        s.cleanup.model = "llama-3.3-70b-versatile"
        s.cleanup.apiKeyEnvVar = "GROQ_API_KEY"
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }
}
