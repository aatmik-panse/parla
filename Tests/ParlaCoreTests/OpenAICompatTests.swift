import XCTest
@testable import ParlaCore

final class OpenAICompatTests: XCTestCase {
    let ctx = CleanupContext(dictionary: [], snippets: [:], appName: nil)

    func testRequestShapeWithKey() async throws {
        let http = MockHTTP()
        http.body = Data(#"{"choices":[{"message":{"content":"Hi."}}]}"#.utf8)
        let client = OpenAICompatClient(
            baseURL: "https://api.openai.com/v1", apiKey: "k", model: "gpt-4o", http: http)
        let out = try await client.clean(transcript: "um hi", context: ctx)
        XCTAssertEqual(out, "Hi.")

        let req = http.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "gpt-4o")
        XCTAssertEqual(json["max_tokens"] as? Int, 1024)
        let messages = json["messages"] as! [[String: Any]]
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, PromptBuilder.system(context: ctx))
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "um hi")
    }

    func testTrailingSlashBaseURLNoDoubleSlash() async throws {
        let http = MockHTTP()
        http.body = Data(#"{"choices":[{"message":{"content":"Hi."}}]}"#.utf8)
        let client = OpenAICompatClient(
            baseURL: "http://localhost:11434/v1/", apiKey: nil, model: "llama3", http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertEqual(http.lastRequest?.url?.absoluteString,
                       "http://localhost:11434/v1/chat/completions")
    }

    func testNoAuthorizationHeaderWhenKeyNil() async throws {
        let http = MockHTTP()
        http.body = Data(#"{"choices":[{"message":{"content":"Hi."}}]}"#.utf8)
        let client = OpenAICompatClient(
            baseURL: "http://localhost:11434/v1", apiKey: nil, model: "llama3", http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertNil(http.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testNon200Throws() async {
        let http = MockHTTP()
        http.status = 500
        http.body = Data([0xFF, 0xFE])
        let client = OpenAICompatClient(baseURL: "http://x/v1", apiKey: "k", model: "m", http: http)
        do {
            _ = try await client.clean(transcript: "x", context: ctx)
            XCTFail("expected throw")
        } catch let error as CleanupError {
            XCTAssertTrue(error.description.contains("500"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testEmptyContentThrows() async {
        let http = MockHTTP()
        http.body = Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)
        let client = OpenAICompatClient(baseURL: "http://x/v1", apiKey: "k", model: "m", http: http)
        do {
            _ = try await client.clean(transcript: "x", context: ctx)
            XCTFail("expected throw")
        } catch {}
    }

    func testMissingContentThrows() async {
        let http = MockHTTP()
        http.body = Data(#"{"choices":[{"message":{}}]}"#.utf8)
        let client = OpenAICompatClient(baseURL: "http://x/v1", apiKey: "k", model: "m", http: http)
        do {
            _ = try await client.clean(transcript: "x", context: ctx)
            XCTFail("expected throw")
        } catch {}
    }
}

final class CleanupSanitizerTests: XCTestCase {
    func testStripsStraightDoubleQuotes() {
        XCTAssertEqual(CleanupSanitizer.sanitize("\"Hello.\""), "Hello.")
    }

    func testStripsStraightSingleQuotes() {
        XCTAssertEqual(CleanupSanitizer.sanitize("'Hi'"), "Hi")
    }

    func testStripsCurlyQuotes() {
        XCTAssertEqual(CleanupSanitizer.sanitize("\u{201C}Hello.\u{201D}"), "Hello.")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(CleanupSanitizer.sanitize("  Hello.  \n"), "Hello.")
    }

    func testNonWrappingQuotesUnchanged() {
        XCTAssertEqual(CleanupSanitizer.sanitize("He said \"hi\" loudly."),
                       "He said \"hi\" loudly.")
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(CleanupSanitizer.sanitize("Just text."), "Just text.")
    }
}
