import XCTest
@testable import ParlaCore

final class HistoryTests: XCTestCase {
    func tempStore() -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return HistoryStore(url: dir.appendingPathComponent("history.json"))
    }

    func testAppendNewestFirst() {
        let store = tempStore()
        store.append(HistoryEntry(raw: "one"))
        store.append(HistoryEntry(raw: "two"))
        XCTAssertEqual(store.entries.map(\.raw), ["two", "one"])
    }

    func testCapDropsOldest() {
        let store = tempStore()
        for i in 0..<(HistoryStore.cap + 5) { store.append(HistoryEntry(raw: "\(i)")) }
        XCTAssertEqual(store.entries.count, HistoryStore.cap)
        XCTAssertEqual(store.entries.first?.raw, "\(HistoryStore.cap + 4)") // newest kept
        XCTAssertEqual(store.entries.last?.raw, "5")                        // oldest 0..4 dropped
    }

    func testPersistenceRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let a = HistoryStore(url: url)
        a.append(HistoryEntry(raw: "raw text", cleaned: "cleaned text", appName: "TextEdit"))
        let b = HistoryStore(url: url) // reload from disk
        XCTAssertEqual(b.entries.count, 1)
        XCTAssertEqual(b.entries.first?.raw, "raw text")
        XCTAssertEqual(b.entries.first?.cleaned, "cleaned text")
        XCTAssertEqual(b.entries.first?.appName, "TextEdit")
    }

    func testClear() {
        let store = tempStore()
        store.append(HistoryEntry(raw: "x"))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(HistoryStore(url: store.url).entries.isEmpty) // persisted
    }

    func testBestPrefersCleaned() {
        XCTAssertEqual(HistoryEntry(raw: "r", cleaned: "c").best, "c")
        XCTAssertEqual(HistoryEntry(raw: "r").best, "r") // nil cleaned falls back to raw
    }

    func testHistoryEnabledDefaultTrue() {
        XCTAssertTrue(Settings().historyEnabled)
    }

    func testHistoryEnabledTolerantDecode() throws {
        // Missing key ⇒ default true; present ⇒ honored; partial file ⇒ no reset.
        let missing = try JSONDecoder().decode(Settings.self, from: Data(#"{"dictionary":["X"]}"#.utf8))
        XCTAssertTrue(missing.historyEnabled)
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"historyEnabled":false}"#.utf8))
        XCTAssertFalse(off.historyEnabled)
    }
}
