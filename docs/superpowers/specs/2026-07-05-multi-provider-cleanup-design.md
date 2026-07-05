# Multi-Provider Cleanup LLM — Design

Approved by user 2026-07-05 ("Continue building with approach one").

## Goal

Let the cleanup step run against any OpenAI-compatible provider (Groq, Gemini,
OpenAI, Mistral, local Ollama/LM Studio) in addition to the existing Anthropic
client. Anthropic stays the default; existing settings.json files keep working.

## Design

**Settings (hardened + extended).** `Settings` gets tolerant decoding
(`decodeIfPresent` for every field, defaults on missing keys) so new fields
never reset a user's file — fixes the deferred Task-1 finding. New nested block:

```swift
public struct CleanupSettings: Codable, Equatable {
    public var provider: String = "anthropic"   // "anthropic" | "openai-compatible"
    public var baseURL: String? = nil            // required for openai-compatible
    public var model: String? = nil              // openai-compatible: required; anthropic: overrides cleanupModel
    public var apiKeyEnvVar: String? = nil       // name of env var holding the key
    public var apiKey: String? = nil             // inline fallback
}
// Settings.cleanup: CleanupSettings = CleanupSettings()
```

Legacy fields (`cleanupModel`, `anthropicApiKey`) remain and act as fallbacks.

**Protocol.** `CleanupProviding` with one method
`clean(transcript: String, context: CleanupContext) async throws -> String`.
Existing `CleanupClient` conforms unchanged.

**OpenAICompatClient** (new, ~80 lines). `POST {baseURL}/chat/completions`,
`Authorization: Bearer <key>` (header omitted when no key — Ollama needs none),
body `{model, max_tokens: 1024, messages: [system, user]}` reusing
`PromptBuilder.system(context:)`. Parses `choices[0].message.content`; non-200
or empty → throws `CleanupError` (pipeline falls back to raw transcript as today).

**Factory** (in ParlaCore, shared by app + eval).
`makeCleanupClient(settings: Settings, env: [String: String]) throws -> CleanupProviding`
Key resolution: `env[cleanup.apiKeyEnvVar]` → `cleanup.apiKey` → legacy
(`env["ANTHROPIC_API_KEY"]` → `anthropicApiKey`, anthropic only). Misconfiguration
(missing baseURL/model for openai-compatible; missing key for anthropic) throws
`CleanupError` → surfaces as the existing raw-transcript fallback in the app and
exit 2 in parla-eval.

**Output sanitizer.** Smaller models wrap output in quotes. `Cleanup.sanitize(_:)`
trims and strips one pair of matching wrapping quotes ("…", '…', "…" curly);
applied to the cleanup result in `Pipeline`. Preamble-stripping deliberately
skipped (risk of eating content) — ponytail note in code.

**Wiring.** `main.swift` and `parla-eval` construct the client via the factory.
README gains preset blocks for Groq and Gemini and an Ollama note.

## Error handling

Unchanged guarantee: any cleanup failure inserts the raw transcript. Provider
misconfig is a cleanup failure, not a crash.

## Testing

MockHTTP request/response tests for OpenAICompatClient (URL join, auth header
present/absent, body shape, choices parsing, non-200); tolerant-decode tests
(old settings.json, partial file, unknown keys); factory resolution tests
(per-provider key/model/misconfig); sanitize tests. Eval E2E re-run for config
error paths.

## Out of scope

Native Gemini/Groq clients, streaming, aggregator routing, provider UI.
