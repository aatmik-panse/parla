import Foundation

/// Builds the cleanup client for the configured provider. Any misconfiguration
/// throws `CleanupError`, which the app surfaces as its raw-transcript fallback
/// and parla-eval surfaces as exit 2.
public func makeCleanupClient(
    settings: Settings, env: [String: String], http: HTTPPosting = URLSessionPoster()
) throws -> CleanupProviding {
    let c = settings.cleanup

    // Key resolution shared by both providers: named env var → inline apiKey.
    // Anthropic additionally falls back to the legacy ANTHROPIC_API_KEY / anthropicApiKey.
    func resolvedKey(anthropicLegacy: Bool) -> String? {
        if let name = c.apiKeyEnvVar, let v = env[name], !v.isEmpty { return v }
        if let k = c.apiKey, !k.isEmpty { return k }
        guard anthropicLegacy else { return nil }
        if let v = env["ANTHROPIC_API_KEY"], !v.isEmpty { return v }
        if let k = settings.anthropicApiKey, !k.isEmpty { return k }
        return nil
    }

    switch c.provider {
    case "openai-compatible":
        guard let baseURL = c.baseURL, !baseURL.isEmpty else {
            throw CleanupError(description: "cleanup.baseURL required for openai-compatible provider")
        }
        guard let model = c.model, !model.isEmpty else {
            throw CleanupError(description: "cleanup.model required for openai-compatible provider")
        }
        return OpenAICompatClient(
            baseURL: baseURL, apiKey: resolvedKey(anthropicLegacy: false), model: model, http: http)
    default:  // "anthropic" or any unknown value
        guard let key = resolvedKey(anthropicLegacy: true) else {
            throw CleanupError(description: "no API key (set ANTHROPIC_API_KEY, cleanup.apiKey/apiKeyEnvVar, or anthropicApiKey)")
        }
        return CleanupClient(apiKey: key, model: c.model ?? settings.cleanupModel, http: http)
    }
}
