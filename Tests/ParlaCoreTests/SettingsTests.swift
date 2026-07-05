import XCTest
@testable import ParlaCore

final class SettingsTests: XCTestCase {
    func tempStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsStore(url: dir.appendingPathComponent("settings.json"))
    }

    func testDefaultsWhenFileMissing() {
        let s = tempStore().load()
        XCTAssertEqual(s.cleanupModel, "claude-haiku-4-5")
        XCTAssertTrue(s.dictionary.isEmpty)
        XCTAssertTrue(s.snippets.isEmpty)
    }

    func testRoundTrip() throws {
        let store = tempStore()
        var s = Settings()
        s.dictionary = ["Kubernetes", "Daksh"]
        s.snippets = ["insert my calendar link": "https://cal.com/daksh"]
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Settings())
    }
}
