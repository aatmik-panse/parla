import XCTest
@testable import ParlaCore

final class MockHTTP: HTTPPosting {
    var lastRequest: URLRequest?
    var status = 200
    var body = Data()
    func post(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: nil)!
        return (body, resp)
    }
}

final class CleanupTests: XCTestCase {
    let ctx = CleanupContext(
        dictionary: ["Kubernetes"],
        snippets: ["calendar link": "https://cal.com/x"],
        appName: "Slack")

    func testSystemPromptContainsContext() {
        let p = PromptBuilder.system(context: ctx)
        XCTAssertTrue(p.contains("Kubernetes"))
        XCTAssertTrue(p.contains("https://cal.com/x"))
        XCTAssertTrue(p.contains("Slack"))
    }

    func testRequestShape() async throws {
        let http = MockHTTP()
        http.body = Data(#"{"content":[{"type":"text","text":"Hi."}]}"#.utf8)
        let client = CleanupClient(apiKey: "sk-test", model: "claude-haiku-4-5", http: http)
        let out = try await client.clean(transcript: "um hi", context: ctx)
        XCTAssertEqual(out, "Hi.")

        let req = http.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 1024)
        let messages = json["messages"] as! [[String: Any]]
        XCTAssertEqual(messages[0]["content"] as? String, "um hi")
    }

    func testNon200Throws() async {
        let http = MockHTTP()
        http.status = 429
        let client = CleanupClient(apiKey: "k", model: "m", http: http)
        do {
            _ = try await client.clean(transcript: "x", context: ctx)
            XCTFail("expected throw")
        } catch {}
    }

    func testNon200WithInvalidUTF8BodyThrows() async {
        let http = MockHTTP()
        http.status = 500
        http.body = Data([0xFF, 0xFE])
        let client = CleanupClient(apiKey: "k", model: "m", http: http)
        do {
            _ = try await client.clean(transcript: "x", context: ctx)
            XCTFail("expected throw")
        } catch let error as CleanupError {
            XCTAssertTrue(error.description.contains("500"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testMultipleTextBlocksConcatenated() async throws {
        let http = MockHTTP()
        http.body = Data(#"{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}"#.utf8)
        let client = CleanupClient(apiKey: "k", model: "m", http: http)
        let out = try await client.clean(transcript: "x", context: ctx)
        XCTAssertEqual(out, "AB")
    }
}
