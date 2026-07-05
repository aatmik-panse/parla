import XCTest
@testable import ParlaCore

final class EvalNormalizeTests: XCTestCase {
    func testCollapsesWhitespace() {
        XCTAssertEqual(Eval.normalize("  Hello,\n  world.  "), "Hello, world.")
    }
    func testCaseAndPunctuationPreserved() {
        XCTAssertEqual(Eval.normalize("Let's meet at 6."), "Let's meet at 6.")
        XCTAssertNotEqual(Eval.normalize("let's meet at 6"), "Let's meet at 6.")
    }
}
