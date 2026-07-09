import XCTest
@testable import ParlaCore

// Routing is verified by issuing a clean() against MockHTTP and inspecting the
// request the factory-built client produces — no network, no schema guessing.
final class CleanupFactoryTests: XCTestCase {
    let ctx = CleanupContext(dictionary: [], snippets: [:], appName: nil)

    private func mock() -> MockHTTP {
        let http = MockHTTP()
        http.body = Data(#"{"content":[{"type":"text","text":"ok"}],"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        return http
    }

    func testAnthropicDefaultUsesLegacyKeyAndModel() async throws {
        var s = Settings()
        s.anthropicApiKey = "legacy-key"
        s.cleanupModel = "claude-haiku-4-5"
        let http = mock()
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)

        let req = http.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "legacy-key")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
    }

    func testAnthropicEnvKeyBeatsLegacy() async throws {
        var s = Settings()
        s.anthropicApiKey = "legacy-key"
        let http = mock()
        let client = try makeCleanupClient(
            settings: s, env: ["ANTHROPIC_API_KEY": "env-key"], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertEqual(http.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "env-key")
    }

    func testEnvVarKeyBeatsInlineApiKey() async throws {
        var s = Settings()
        s.cleanup.apiKeyEnvVar = "MY_KEY"
        s.cleanup.apiKey = "inline-key"
        let http = mock()
        let client = try makeCleanupClient(
            settings: s, env: ["MY_KEY": "env-var-key"], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertEqual(http.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "env-var-key")
    }

    func testAnthropicCleanupModelOverride() async throws {
        var s = Settings()
        s.anthropicApiKey = "k"
        s.cleanupModel = "claude-haiku-4-5"
        s.cleanup.model = "claude-sonnet-4-5"
        let http = mock()
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        let json = try JSONSerialization.jsonObject(with: http.lastRequest!.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-5")
    }

    func testAnthropicMissingKeyThrows() {
        let s = Settings()  // no key anywhere
        XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:])) { error in
            XCTAssertTrue("\(error)".lowercased().contains("key"))
        }
    }

    func testCleanupWarmURLMatchesConfiguredProvider() {
        var s = Settings()
        XCTAssertNil(cleanupWarmURL(settings: s, env: [:]))
        XCTAssertEqual(cleanupWarmURL(settings: s, env: ["ANTHROPIC_API_KEY": "k"])?.absoluteString,
                       "https://api.anthropic.com")

        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "http://localhost:11434/v1"
        s.cleanup.model = "llama3"
        XCTAssertEqual(cleanupWarmURL(settings: s, env: [:])?.absoluteString,
                       "http://localhost:11434/v1")
        s.cleanup.model = nil
        XCTAssertNil(cleanupWarmURL(settings: s, env: [:]))
    }

    func testUnknownProviderTreatedAsAnthropic() async throws {
        var s = Settings()
        s.cleanup.provider = "some-future-thing"
        s.anthropicApiKey = "k"
        let http = mock()
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertEqual(http.lastRequest?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testOpenAICompatUsesBearerAndEndpoint() async throws {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "https://api.groq.com/openai/v1"
        s.cleanup.model = "llama-3.3-70b-versatile"
        s.cleanup.apiKeyEnvVar = "GROQ_API_KEY"
        let http = mock()
        let client = try makeCleanupClient(
            settings: s, env: ["GROQ_API_KEY": "gk"], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)

        let req = http.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer gk")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "llama-3.3-70b-versatile")
    }

    func testOpenAICompatKeyOptional() async throws {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "http://localhost:11434/v1"
        s.cleanup.model = "llama3"
        let http = mock()
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertNil(http.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAICompatMissingBaseURLThrows() {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.model = "m"
        XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:])) { error in
            XCTAssertTrue("\(error)".lowercased().contains("baseurl"))
        }
    }

    func testOpenAICompatMissingModelThrows() {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "http://x/v1"
        XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:])) { error in
            XCTAssertTrue("\(error)".lowercased().contains("model"))
        }
    }
}
