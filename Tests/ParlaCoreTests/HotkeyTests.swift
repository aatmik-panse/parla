import XCTest
@testable import ParlaCore

final class HotkeyTests: XCTestCase {
    /// Drive the pure machine with (keyCode, fnActive, time) events.
    func edges(_ events: [(UInt16, Bool, TimeInterval)]) -> [HotkeyMonitor.Edge] {
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        for (code, active, t) in events { m.handle(keyCode: code, fnActive: active, at: t) }
        return out
    }

    func testLongPressAndRelease() {
        XCTAssertEqual(edges([(63, true, 0), (63, false, 0.5)]), [.down, .up(short: false)])
    }

    func testShortTapFlaggedShort() {
        XCTAssertEqual(edges([(63, true, 0), (63, false, 0.1)]), [.down, .up(short: true)])
    }

    func testOtherModifierIgnored() {
        XCTAssertEqual(edges([(58, true, 0), (58, false, 0.5)]), [])
    }

    func testRepeatedDownFiresOnce() {
        XCTAssertEqual(edges([(63, true, 0), (63, true, 0.1), (63, false, 0.5)]),
                       [.down, .up(short: false)])
    }

    func testUpWithoutDownIgnored() {
        XCTAssertEqual(edges([(63, false, 0)]), [])
    }

    func testKeypressWhileHeldCancelsAndSwallowsUp() {
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        m.handle(keyCode: 63, fnActive: true, at: 0)
        m.otherKeyDown()                                   // fn+arrow / Esc
        m.handle(keyCode: 63, fnActive: false, at: 0.5)    // fn released after
        XCTAssertEqual(out, [.down, .cancel])              // no trailing .up
    }

    func testKeypressWhileIdleIgnored() {
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        m.otherKeyDown()
        XCTAssertEqual(out, [])
    }
}
