import XCTest
@testable import ParlaCore

final class HotkeyTests: XCTestCase {
    func monitor(_ out: UnsafeMutablePointer<[HotkeyMonitor.Edge]>) -> HotkeyMonitor {
        let m = HotkeyMonitor()
        m.onEdge = { out.pointee.append($0) }
        return m
    }

    /// Drive the pure machine with (keyCode, fnActive, time) flagsChanged events.
    func edges(_ events: [(UInt16, Bool, TimeInterval)]) -> [HotkeyMonitor.Edge] {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        for (code, active, t) in events { m.handle(keyCode: code, fnActive: active, at: t) }
        return out
    }

    // MARK: push-to-talk (unchanged behavior)

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
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, shiftActive: true, at: 0)
        m.handle(keyCode: 63, fnActive: false, shiftActive: false, at: 0.5) // shift released while speaking
        XCTAssertEqual(out, [.down(command: true), .up(short: false)])
    }

    func testCommandModeLatchedAtDownNotUp() {
        // Shift held only at release (not at fn-down) ⇒ plain dictation.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, shiftActive: false, at: 0)
        m.handle(keyCode: 63, fnActive: false, shiftActive: true, at: 0.5)
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testShiftFlagsChangedDoesNotDoubleFireOrCancel() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
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
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        XCTAssertFalse(m.keyDown(keyCode: 123, fnActive: true, at: 0.2)) // fn+arrow: cancels, passes through
        m.handle(keyCode: 63, fnActive: false, at: 0.5)                  // fn released after
        XCTAssertEqual(out, [.down(command: false), .cancel])            // no trailing .up
    }

    func testKeypressWhileIdleIgnored() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 0, at: 0))
        XCTAssertEqual(out, [])
    }

    // MARK: hands-free (fn+Space)

    func testHandsFreeLatchSurvivesFnReleaseAndStops() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)                       // fn down → push
        XCTAssertTrue(m.keyDown(keyCode: 49, fnActive: true, at: 0.1))     // fn+Space: latch, swallowed
        m.handle(keyCode: 63, fnActive: false, at: 0.3)                    // fn release: NO .up
        XCTAssertEqual(out, [.down(command: false), .handsFree])
        XCTAssertTrue(m.keyDown(keyCode: 49, fnActive: true, at: 5))       // fn+Space again: stop
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testTypingDuringHandsFreeDoesNotCancel() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)                // latch hands-free
        m.handle(keyCode: 63, fnActive: false, at: 0.3)
        XCTAssertFalse(m.keyDown(keyCode: 0, at: 1))                       // plain typing passes through
        XCTAssertFalse(m.keyDown(keyCode: 49, at: 2))                      // plain space too (no fn)
        XCTAssertEqual(out, [.down(command: false), .handsFree])           // still recording
    }

    func testEscCancelsHandsFree() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)
        m.handle(keyCode: 63, fnActive: false, at: 0.3)
        XCTAssertTrue(m.keyDown(keyCode: 53, at: 1))                       // Esc: cancel, swallowed
        XCTAssertEqual(out, [.down(command: false), .handsFree, .cancel])
    }

    func testFnHeldThroughStopStartsFreshHandsFree() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)                // latch
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 2)                  // stop (fn never released)
        XCTAssertTrue(m.keyDown(keyCode: 49, fnActive: true, at: 3))       // start again from idle
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false),
                             .down(command: false), .handsFree])
    }

    // MARK: esc + paste-last while idle

    func testEscWhileHeldCancelsAndIsSwallowed() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        XCTAssertTrue(m.keyDown(keyCode: 53, fnActive: true, at: 0.2))
        XCTAssertEqual(out, [.down(command: false), .cancel])
    }

    func testEscWhileIdleDismissesAndPassesThrough() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 53, at: 0))
        XCTAssertEqual(out, [.dismiss])
    }

    func testCtrlCmdVPastesLastAndIsSwallowed() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertTrue(m.keyDown(keyCode: 9, cmd: true, ctrl: true, at: 0))
        XCTAssertEqual(out, [.pasteLast])
    }

    func testPlainCmdVIgnored() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 9, cmd: true, at: 0))
        XCTAssertEqual(out, [])
    }
}
