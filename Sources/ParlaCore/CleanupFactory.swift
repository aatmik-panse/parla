import Foundation

private func resolvedCleanupKey(
    settings: Settings, env: [String: String], anthropicLegacy: Bool
) -> String? {
    let c = settings.cleanup
    if let name = c.apiKeyEnvVar, let v = env[name], !v.isEmpty { return v }
    if let k = c.apiKey, !k.isEmpty { return k }
    guard anthropicLegacy else { return nil }
    if let v = env["ANTHROPIC_API_KEY"], !v.isEmpty { return v }
    if let k = settings.anthropicApiKey, !k.isEmpty { return k }
    return nil
}

/// Base URL usable for cleanup: parses, http(s) scheme, has a host. Anything
/// else is misconfiguration — callers must refuse it up front, never hand it
/// to a client that would build a request URL from it.
private func validBaseURL(_ raw: String?) -> URL? {
    guard let raw, !raw.isEmpty, let url = URL(string: raw),
          ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
    return url
}

/// Provider URL to pre-warm, or nil when cleanup is not configured.
public func cleanupWarmURL(settings: Settings, env: [String: String]) -> URL? {
    let c = settings.cleanup
    switch c.provider {
    case "openai-compatible":
        guard let url = validBaseURL(c.baseURL) else { return nil }
        return url
    default:
        guard resolvedCleanupKey(settings: settings, env: env, anthropicLegacy: true) != nil else {
            return nil
        }
        return URL(string: "https://api.anthropic.com")
    }
}

/// Builds the cleanup client for the configured provider. Any misconfiguration
/// throws `CleanupError`, which the app surfaces as its raw-transcript fallback
/// and parla-eval surfaces as exit 2.
public func makeCleanupClient(
    settings: Settings, env: [String: String], http: HTTPPosting = URLSessionPoster()
) throws -> CleanupProviding {
    let c = settings.cleanup

    switch c.provider {
    case "openai-compatible":
        guard let baseURL = c.baseURL, !baseURL.isEmpty else {
            throw CleanupError(description: "cleanup.baseURL required for openai-compatible provider")
        }
        guard validBaseURL(baseURL) != nil else {
            throw CleanupError(description: "cleanup.baseURL is not a valid http(s) URL: \(baseURL)")
        }
        // model optional: nil ⇒ the client asks the server for its first model
        let model = (c.model?.isEmpty ?? true) ? nil : c.model
        return OpenAICompatClient(
            baseURL: baseURL,
            apiKey: resolvedCleanupKey(settings: settings, env: env, anthropicLegacy: false),
            model: model, http: http)
    default:  // "anthropic" or any unknown value
        guard let key = resolvedCleanupKey(settings: settings, env: env, anthropicLegacy: true) else {
            throw CleanupError(description: "no API key (set ANTHROPIC_API_KEY, cleanup.apiKey/apiKeyEnvVar, or anthropicApiKey)")
        }
        return CleanupClient(apiKey: key, model: c.model ?? settings.cleanupModel, http: http)
    }
}
