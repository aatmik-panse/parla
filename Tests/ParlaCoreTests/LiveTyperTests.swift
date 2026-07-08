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

    // MARK: swapPlan (raw → cleaned after instant finalize)

    func testSwapPlanEqualIsNil() {
        XCTAssertNil(LiveTyper.swapPlan(raw: "hello", cleaned: "hello"))
    }

    func testSwapPlanEqualAfterTrimmingIsNil() {
        XCTAssertNil(LiveTyper.swapPlan(raw: "hello", cleaned: " hello \n"))
    }

    func testSwapPlanTailRevision() {
        let p = LiveTyper.swapPlan(raw: "helo world", cleaned: "hello world")!
        XCTAssertEqual(p.eraseTail, "o world") // diverges after "hel"
        XCTAssertEqual(p.replacement, "lo world")
    }

    func testSwapPlanPureAppendErasesOneGrapheme() {
        // Extension keeps the verify tail non-empty: erase "i", retype "i there".
        let p = LiveTyper.swapPlan(raw: "hi", cleaned: "hi there")!
        XCTAssertEqual(p.eraseTail, "i")
        XCTAssertEqual(p.replacement, "i there")
    }

    func testSwapPlanShrinkHasEmptyReplacement() {
        let p = LiveTyper.swapPlan(raw: "hi there", cleaned: "hi")!
        XCTAssertEqual(p.eraseTail, " there")
        XCTAssertEqual(p.replacement, "")
    }

    func testSwapPlanFullRewrite() {
        let p = LiveTyper.swapPlan(raw: "abc", cleaned: "xyz")!
        XCTAssertEqual(p.eraseTail, "abc")
        XCTAssertEqual(p.replacement, "xyz")
    }

    func testSwapPlanEmptyCleanedIsNil() {
        // A sanitizer-emptied cleanup must never erase the dictation.
        XCTAssertNil(LiveTyper.swapPlan(raw: "hello world", cleaned: ""))
        XCTAssertNil(LiveTyper.swapPlan(raw: "hello world", cleaned: " \n"))
    }

    func testSwapPlanNeverEmptyTailForNonEmptyRaw() {
        // Property: the tail we verify/erase must never be empty (opaque-field
        // select-back verification needs something to check).
        for (raw, cleaned) in [("a", "ab"), ("hello", "hello!"), ("x y", "x z"), ("end.", "end")] {
            let p = LiveTyper.swapPlan(raw: raw, cleaned: cleaned)!
            XCTAssertFalse(p.eraseTail.isEmpty, "\(raw) -> \(cleaned)")
            XCTAssertTrue(raw.hasSuffix(p.eraseTail))
            // Applying the plan reproduces cleaned.
            XCTAssertEqual(String(raw.dropLast(p.eraseTail.count)) + p.replacement, cleaned)
        }
    }
}
