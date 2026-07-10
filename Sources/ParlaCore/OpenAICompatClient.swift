import Foundation

/// Cleanup via any OpenAI-compatible /chat/completions endpoint (OpenAI, Ollama, etc.).
/// `apiKey` is optional so keyless local servers (Ollama) work without an Authorization header.
/// `model` is optional too: when nil, the server's first listed model is used.
public struct OpenAICompatClient: CleanupProviding {
    let baseURL: String
    let apiKey: String?
    let model: String?
    let http: HTTPPosting

    public init(baseURL: String, apiKey: String?, model: String?,
                http: HTTPPosting = URLSessionPoster()) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.http = http
    }

    // ponytail: re-fetched every call when model is empty; cache it if the
    // extra GET per dictation ever matters.
    private func firstServerModel(base: String) async throws -> String {
        guard let url = URL(string: base + "/models") else {
            throw CleanupError(description: "invalid cleanup base URL: \(baseURL)")
        }
        var req = URLRequest(url: url)
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        let (data, response) = try await http.post(req)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw CleanupError(description: "couldn't list models to pick a default")
        }
        struct Models: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let first = try JSONDecoder().decode(Models.self, from: data).data.first else {
            throw CleanupError(description: "server lists no models")
        }
        return first.id
    }

    public func clean(transcript: String, context: CleanupContext) async throws -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let modelID: String
        if let model { modelID = model } else { modelID = try await firstServerModel(base: base) }
        guard let url = URL(string: base + "/chat/completions") else {
            throw CleanupError(description: "invalid cleanup base URL: \(baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "model": modelID,
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
