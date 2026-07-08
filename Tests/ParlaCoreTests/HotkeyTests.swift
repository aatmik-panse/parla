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
        XCTAssertEqual(edges([(63, true, 0), (63, false, 0.5)]), [.down(command: false), .up(short: false)])
    }

    func testShortTapFlaggedShort() {
        XCTAssertEqual(edges([(63, true, 0), (63, false, 0.1)]), [.down(command: false), .up(short: true)])
    }

    func testOtherModifierIgnored() {
        XCTAssertEqual(edges([(58, true, 0), (58, false, 0.5)]), [])
    }

    func testRepeatedDownFiresOnce() {
        XCTAssertEqual(edges([(63, true, 0), (63, true, 0.1), (63, false, 0.5)]),
                       [.down(command: false), .up(short: false)])
    }

    func testShiftAtDownIsCommand() {
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        m.handle(keyCode: 63, fnActive: true, shiftActive: true, at: 0)
        m.handle(keyCode: 63, fnActive: false, shiftActive: false, at: 0.5) // shift released while speaking
        XCTAssertEqual(out, [.down(command: true), .up(short: false)])
    }

    func testCommandModeLatchedAtDownNotUp() {
        // Shift held only at release (not at fn-down) ⇒ plain dictation.
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        m.handle(keyCode: 63, fnActive: true, shiftActive: false, at: 0)
        m.handle(keyCode: 63, fnActive: false, shiftActive: true, at: 0.5)
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testShiftFlagsChangedDoesNotDoubleFireOrCancel() {
        // Shift transitions arrive via flagsChanged with keyCode 56 (≠63): they
        // must produce no extra .down and never a .cancel mid-dictation.
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        m.handle(keyCode: 63, fnActive: true, shiftActive: false, at: 0)    // fn down
        m.handle(keyCode: 56, fnActive: true, shiftActive: true, at: 0.1)   // shift pressed
        m.handle(keyCode: 56, fnActive: true, shiftActive: false, at: 0.2)  // shift released
        m.handle(keyCode: 63, fnActive: false, shiftActive: false, at: 0.5) // fn up
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
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
        XCTAssertEqual(out, [.down(command: false), .cancel]) // no trailing .up
    }

    func testKeypressWhileIdleIgnored() {
        let m = HotkeyMonitor()
        var out: [HotkeyMonitor.Edge] = []
        m.onEdge = { out.append($0) }
        m.otherKeyDown()
        XCTAssertEqual(out, [])
    }
}
