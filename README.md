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
System Settings > Privacy & Security. Then hold **Right ⌥ (Option)** and speak;
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

## Build & test

```sh
swift build
swift test
```
