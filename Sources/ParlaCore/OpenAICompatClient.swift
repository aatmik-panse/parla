import Foundation

/// Cleanup via any OpenAI-compatible /chat/completions endpoint (OpenAI, Ollama, etc.).
/// `apiKey` is optional so keyless local servers (Ollama) work without an Authorization header.
public struct OpenAICompatClient: CleanupProviding {
    let baseURL: String
    let apiKey: String?
    let model: String
    let http: HTTPPosting

    public init(baseURL: String, apiKey: String?, model: String,
                http: HTTPPosting = URLSessionPoster()) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.http = http
    }

    public func clean(transcript: String, context: CleanupContext) async throws -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": PromptBuilder.system(context: context)],
                ["role": "user", "content": transcript],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await http.post(req)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            throw CleanupError(description: "cleanup API \(code): \(snippet)")
        }

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.choices.first?.message.content ?? ""
        guard !text.isEmpty else { throw CleanupError(description: "empty response") }
        return text
    }
}
