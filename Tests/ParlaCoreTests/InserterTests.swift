import XCTest
@testable import ParlaCore

final class InserterTests: XCTestCase {
    func assertValidChunks(_ chunks: [[UInt16]], reproduce units: [UInt16]) {
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty)
            XCTAssertLessThanOrEqual(chunk.count, 20)
            // No chunk ends with a lone high surrogate...
            if let last = chunk.last {
                XCTAssertFalse((0xD800...0xDBFF).contains(last), "chunk ends with unpaired high surrogate")
            }
            // ...or starts with a lone low surrogate.
            if let first = chunk.first {
                XCTAssertFalse((0xDC00...0xDFFF).contains(first), "chunk starts with unpaired low surrogate")
            }
        }
        XCTAssertEqual(chunks.flatMap { $0 }, units)
    }

    func testASCIIChunksExactlyAtMax() {
        let units = Array(String(repeating: "a", count: 45).utf16)
        let chunks = Inserter.chunkUTF16(units)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
        assertValidChunks(chunks, reproduce: units)
    }

    func testSurrogatePairStraddlingBoundaryNotSplit() {
        // 19 ASCII units then an emoji (2 UTF-16 units) — the pair would straddle index 20.
        let text = String(repeating: "x", count: 19) + "😀😀😀"
        let units = Array(text.utf16)
        let chunks = Inserter.chunkUTF16(units)
        assertValidChunks(chunks, reproduce: units)
        // First chunk must stop at 19 to keep the pair intact.
        XCTAssertEqual(chunks[0].count, 19)
    }

    func testAllEmoji() {
        let units = Array(String(repeating: "😀", count: 25).utf16) // 50 units
        let chunks = Inserter.chunkUTF16(units)
        assertValidChunks(chunks, reproduce: units)
    }
}
