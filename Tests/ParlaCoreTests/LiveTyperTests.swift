import XCTest
@testable import ParlaCore

final class LiveTyperTests: XCTestCase {
    func testPureAppend() {
        let d = LiveTyper.diff(typed: "hello", new: "hello world")
        XCTAssertEqual(d.erase, 0)
        XCTAssertEqual(d.append, " world")
    }

    func testRevisionMidWord() {
        let d = LiveTyper.diff(typed: "hello wor", new: "hello world")
        XCTAssertEqual(d.erase, 0)
        XCTAssertEqual(d.append, "ld")
    }

    func testFullRewrite() {
        let d = LiveTyper.diff(typed: "abc", new: "xyz")
        XCTAssertEqual(d.erase, 3)
        XCTAssertEqual(d.append, "xyz")
    }

    func testEqualStrings() {
        let d = LiveTyper.diff(typed: "same", new: "same")
        XCTAssertEqual(d.erase, 0)
        XCTAssertEqual(d.append, "")
    }

    func testTypedEmpty() {
        let d = LiveTyper.diff(typed: "", new: "abc")
        XCTAssertEqual(d.erase, 0)
        XCTAssertEqual(d.append, "abc")
    }

    func testNewEmpty() {
        let d = LiveTyper.diff(typed: "abc", new: "")
        XCTAssertEqual(d.erase, 3)
        XCTAssertEqual(d.append, "")
    }

    func testEmojiCountsAsOneErase() {
        // 😀 is 2 UTF-16 units but one grapheme → one backspace.
        let d = LiveTyper.diff(typed: "hi😀", new: "hi")
        XCTAssertEqual(d.erase, 1)
        XCTAssertEqual(d.append, "")
    }

    func testCombiningCharCountsAsOneErase() {
        // "é" as e + combining acute is one grapheme → one backspace.
        let d = LiveTyper.diff(typed: "cafe\u{301}", new: "caf")
        XCTAssertEqual(d.erase, 1)
        XCTAssertEqual(d.append, "")
    }
}
