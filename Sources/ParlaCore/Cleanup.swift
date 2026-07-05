import Foundation

public struct CleanupContext {
    public var dictionary: [String]
    public var snippets: [String: String]
    public var appName: String?
    public init(dictionary: [String], snippets: [String: String], appName: String?) {
        self.dictionary = dictionary
        self.snippets = snippets
        self.appName = appName
    }
}

public enum PromptBuilder {
    public static func system(context: CleanupContext) -> String {
        var p = """
        You clean up dictated speech into polished text. Output ONLY the cleaned \
        text — no commentary, no quotes, no preamble.

        Rules:
        - Fix punctuation, capitalization, and grammar.
        - Remove filler words (um, uh, like, you know, sort of) and false starts.
        - Apply self-corrections: when the speaker corrects themselves \
        ("at 5... actually 6"), keep only the final version.
        - Preserve the speaker's meaning and content. Do not add, summarize, or answer.
        - Keep the speaker's language (do not translate).
        """
        if !context.dictionary.isEmpty {
            p += "\n\nUse these exact spellings when the words occur: "
                + context.dictionary.joined(separator: ", ") + "."
        }
        if !context.snippets.isEmpty {
            p += "\n\nSnippets — if the transcript matches or contains one of these "
                + "trigger phrases, replace the phrase with its expansion:\n"
            for (k, v) in context.snippets.sorted(by: { $0.key < $1.key }) {
                p += "- \"\(k)\" -> \(v)\n"
            }
        }
        if let app = context.appName {
            p += "\n\nThe text will be inserted into \(app). Match the tone typical "
                + "for that app (casual for chat, formal for email, plain for code/terminals)."
        }
        return p
    }
}

public protocol HTTPPosting {
    func post(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionPoster: HTTPPosting {
    public init() {}
    public func post(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

public struct CleanupError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

public protocol CleanupProviding {
    func clean(transcript: String, context: CleanupContext) async throws -> String
}

public enum CleanupSanitizer {
    // Strip ONE wrapping quote pair only when the first and last chars are a matching
    // pair. ponytail: no preamble stripping ("Sure, here's..." etc.) — too risky to
    // guess where the model's chatter ends and the user's text begins; upgrade only if
    // a provider proves reliably chatty.
    static let pairs: [(Character, Character)] = [
        ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"),
    ]

    public static func sanitize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last, trimmed.count >= 2 else {
            return trimmed
        }
        for (open, close) in pairs where first == open && last == close {
            return String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

public struct CleanupClient: CleanupProviding {
    let apiKey: String
    let model: String
    let http: HTTPPosting

    public init(apiKey: String, model: String, http: HTTPPosting = URLSessionPoster()) {
        self.apiKey = apiKey
        self.model = model
        self.http = http
    }

    public func clean(transcript: String, context: CleanupContext) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": PromptBuilder.system(context: context),
            "messages": [["role": "user", "content": transcript]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await http.post(req)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            throw CleanupError(description: "cleanup API \(code): \(snippet)")
        }

        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.content.filter { $0.type == "text" }
            .compactMap(\.text).joined()
        guard !text.isEmpty else { throw CleanupError(description: "empty response") }
        return text
    }
}
