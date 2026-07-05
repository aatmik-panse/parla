# Parla

Parla is a macOS menu-bar dictation app: hold a hotkey, speak, release — your speech is transcribed on-device with whisper.cpp, cleaned up by a Claude model, and typed into whatever app you're using.

## Build

```sh
swift build
```

## Test

```sh
swift test
```

## Bundle the app

```sh
scripts/make-app.sh
open Parla.app
```

## Permissions

Parla needs:

- **Microphone** — to record while you hold the hotkey.
- **Accessibility** — to listen for the global hotkey and type text into the frontmost app (System Settings > Privacy & Security > Accessibility).

## Configuration

- Set the `ANTHROPIC_API_KEY` environment variable (or configure the key in settings) for transcript cleanup. Settings live at `~/Library/Application Support/Parla/settings.json`.
- Download a whisper model with `scripts/download-model.sh` before first use.
