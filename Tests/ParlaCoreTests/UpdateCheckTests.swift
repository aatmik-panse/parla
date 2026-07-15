import XCTest
@testable import ParlaCore

final class UpdateCheckTests: XCTestCase {
    func testStripsLeadingV() {
        XCTAssertTrue(UpdateCheck.isNewer(remote: "v0.2.0", current: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "v0.1.0", current: "v0.1.0"))
    }

    func testNumericNotStringCompare() {
        XCTAssertTrue(UpdateCheck.isNewer(remote: "0.10.0", current: "0.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.9.0", current: "0.10.0"))
    }

    func testUnequalComponentCounts() {
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.1", current: "0.1.0")) // 0.1 == 0.1.0
        XCTAssertTrue(UpdateCheck.isNewer(remote: "0.1.1", current: "0.1"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.1", current: "0.1.1"))
    }

    func testSameVersionNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(remote: "1.2.3", current: "1.2.3"))
    }

    func testGarbageTagsDoNotCrash() {
        // Non-numeric components parse as 0 rather than crashing: "1.2.0-beta"
        // and "1.2.1-rc1" both reduce to 1.2.0, so neither beats 1.2.0.
        XCTAssertFalse(UpdateCheck.isNewer(remote: "v1.2.0-beta", current: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "1.2.1-rc1", current: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "nightly", current: "0.1.0"))
        // A prerelease suffix on an already-bumped component still detects newer.
        XCTAssertTrue(UpdateCheck.isNewer(remote: "1.3.0-rc1", current: "1.2.0"))
    }

    func testDecodeSampleReleasePayload() throws {
        let json = Data(#"""
        {"tag_name":"v0.2.0","html_url":"https://github.com/wannabeepolymath/parla/releases/tag/v0.2.0","name":"0.2.0","extra":true}
        """#.utf8)
        let release = try JSONDecoder().decode(UpdateCheck.Release.self, from: json)
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.htmlURL, "https://github.com/wannabeepolymath/parla/releases/tag/v0.2.0")
    }

    func testDecodeMissingHtmlURL() throws {
        let release = try JSONDecoder().decode(UpdateCheck.Release.self, from: Data(#"{"tag_name":"v0.3.0"}"#.utf8))
        XCTAssertEqual(release.tagName, "v0.3.0")
        XCTAssertNil(release.htmlURL)
    }
}
