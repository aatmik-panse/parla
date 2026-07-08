import XCTest
@testable import ParlaCore

final class PipelineTests: XCTestCase {
    func makePipeline(transcript: String,
                      cleanup: @escaping (String, CleanupContext) async throws -> String)
    -> Pipeline {
        var settings = Settings()
        settings.dictionary = ["Kubernetes", "Daksh"]
        return Pipeline(
            transcribe: { _, prompt in
                XCTAssertEqual(prompt, "Kubernetes, Daksh")
                return transcript
            },
            cleanup: cleanup,
            settings: { settings },
            frontAppName: { "Mail" })
    }

    func testHappyPath() async {
        let p = makePipeline(transcript: "um hello") { t, ctx in
            XCTAssertEqual(t, "um hello")
            XCTAssertEqual(ctx.appName, "Mail")
            return "Hello."
        }
        let out = await p.process(samples: [0.1])
        XCTAssertEqual(out, "Hello.")
    }

    func testCleanupResultIsSanitized() async {
        let p = makePipeline(transcript: "um hello") { _, _ in "\"Cleaned.\"" }
        let out = await p.process(samples: [0.1])
        XCTAssertEqual(out, "Cleaned.")
    }

    func testCleanupFailureFallsBackToRawTranscript() async {
        let p = makePipeline(transcript: "raw words") { _, _ in
            throw CleanupError(description: "boom")
        }
        let out = await p.process(samples: [0.1])
        XCTAssertEqual(out, "raw words")
    }

    func testCleanReportsFailureOnThrow() async {
        let p = makePipeline(transcript: "raw words") { _, _ in
            throw CleanupError(description: "boom")
        }
        let result = await p.clean(transcript: "raw words")
        XCTAssertEqual(result.text, "raw words")
        XCTAssertTrue(result.failed)
    }

    func testCleanReportsSuccess() async {
        let p = makePipeline(transcript: "raw words") { t, _ in "Raw words." }
        let result = await p.clean(transcript: "raw words")
        XCTAssertEqual(result.text, "Raw words.")
        XCTAssertFalse(result.failed)
    }

    func testEmptyTranscriptReturnsNil() async {
        let p = makePipeline(transcript: "  ") { t, _ in t }
        let out = await p.process(samples: [0.1])
        XCTAssertNil(out)
    }
}
