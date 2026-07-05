import XCTest
@testable import ParlaCore

final class HotkeyTests: XCTestCase {
    func edges(for events: [(UInt16, Bool)]) -> [HotkeyMonitor.Edge] {
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        for (code, active) in events { m.handle(keyCode: code, optionActive: active) }
        return out
    }

    func testPressAndRelease() {
        XCTAssertEqual(edges(for: [(61, true), (61, false)]), [.down, .up])
    }

    func testLeftOptionIgnored() {
        XCTAssertEqual(edges(for: [(58, true), (58, false)]), [])
    }

    func testRepeatedDownFiresOnce() {
        XCTAssertEqual(edges(for: [(61, true), (61, true), (61, false)]), [.down, .up])
    }

    func testUpWithoutDownIgnored() {
        XCTAssertEqual(edges(for: [(61, false)]), [])
    }
}
