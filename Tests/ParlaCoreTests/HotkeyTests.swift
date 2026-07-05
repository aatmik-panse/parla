import XCTest
@testable import ParlaCore

final class HotkeyTests: XCTestCase {
    func edges(for events: [(UInt16, Bool)]) -> [HotkeyMonitor.Edge] {
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        for (code, active) in events { m.handle(keyCode: code, fnActive: active) }
        return out
    }

    func testPressAndRelease() {
        XCTAssertEqual(edges(for: [(63, true), (63, false)]), [.down, .up])
    }

    func testOtherModifierIgnored() {
        XCTAssertEqual(edges(for: [(58, true), (58, false)]), [])
    }

    func testRepeatedDownFiresOnce() {
        XCTAssertEqual(edges(for: [(63, true), (63, true), (63, false)]), [.down, .up])
    }

    func testUpWithoutDownIgnored() {
        XCTAssertEqual(edges(for: [(63, false)]), [])
    }
}
