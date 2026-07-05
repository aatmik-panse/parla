# Parla

Parla is a macOS menu-bar dictation app: hold a hotkey, speak, release — your speech is transcribed on-device with whisper.cpp, cleaned up by a Claude model, and typed into whatever app you're using.

## First run

```sh
scripts/download-model.sh          # fetch a whisper model (default: base.en)
export ANTHROPIC_API_KEY=sk-ant-…  # optional; used for transcript cleanup
scripts/make-app.sh                # build + bundle Parla.app
open Parla.app
```

On first launch Parla lives in the menu bar (no dock icon) and shows 🎤. macOS
will prompt for **Microphone** and **Accessibility** permission — grant both in
System Settings > Privacy & Security. Then hold **fn 🌐 (Globe)** and speak;
release to transcribe, clean up, and type the text into the frontmost app.

The menu-bar icon reflects state: 🎤 idle · 🔴 recording · … processing · ⚠️
problem (no model loaded, or the mic failed to start).

## Permissions

Parla needs:

- **Microphone** — to record while you hold the hotkey.
- **Accessibility** — to listen for the global hotkey and type text into the frontmost app (System Settings > Privacy & Security > Accessibility).

## Configuration

Settings live at `~/Library/Application Support/Parla/settings.json` — use the
menu-bar **Open Settings File** item to create and edit it. Fields:

- `dictionary` — array of exact spellings (names, jargon) to bias transcription and cleanup, e.g. `["Parla", "whisper.cpp"]`.
- `snippets` — object mapping a spoken trigger phrase to its expansion, e.g. `{"my address": "123 Main St"}`.
- `cleanupModel` — Anthropic model id for cleanup (default `claude-haiku-4-5`).
- `anthropicApiKey` — API key for cleanup. The `ANTHROPIC_API_KEY` environment variable takes precedence; if neither is set, Parla inserts the raw transcript.
- `whisperModelPath` — absolute path to a ggml whisper model. Defaults to the model downloaded by `scripts/download-model.sh`.

## Cleanup providers

Cleanup defaults to **Anthropic** (the `cleanupModel` + `anthropicApiKey`/`ANTHROPIC_API_KEY` fields above); leave `cleanup` unset to keep that behavior. To use any OpenAI-compatible endpoint (Groq, Gemini, OpenAI, local Ollama/LM Studio), add a `cleanup` block:

- `cleanup.provider` — `"anthropic"` (default) or `"openai-compatible"`.
- `cleanup.baseURL` — required for `openai-compatible`; the API root (Parla POSTs to `{baseURL}/chat/completions`).
- `cleanup.model` — required for `openai-compatible`; for Anthropic it overrides `cleanupModel`.
- `cleanup.apiKeyEnvVar` — name of the env var holding the key (takes precedence over `cleanup.apiKey`).
- `cleanup.apiKey` — inline key fallback. Omit both for keyless local servers (Ollama).

Key resolution: `cleanup.apiKeyEnvVar` → `cleanup.apiKey` → (Anthropic only) `ANTHROPIC_API_KEY` → `anthropicApiKey`. Any misconfiguration falls back to inserting the raw transcript.

**Groq** (set `GROQ_API_KEY`):

```json
"cleanup": {
  "provider": "openai-compatible",
  "baseURL": "https://api.groq.com/openai/v1",
  "model": "llama-3.3-70b-versatile",
  "apiKeyEnvVar": "GROQ_API_KEY"
}
```

**Gemini** (set `GEMINI_API_KEY`):

```json
"cleanup": {
  "provider": "openai-compatible",
  "baseURL": "https://generativelanguage.googleapis.com/v1beta/openai",
  "model": "gemini-2.5-flash",
  "apiKeyEnvVar": "GEMINI_API_KEY"
}
```

**Ollama** (local, no key):

```json
"cleanup": {
  "provider": "openai-compatible",
  "baseURL": "http://localhost:11434/v1",
  "model": "llama3.1"
}
```

## Build & test

```sh
swift build
swift test
```
