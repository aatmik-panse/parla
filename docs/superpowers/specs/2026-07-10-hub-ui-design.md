# Parla Hub — Management UI Design

Scope: a SwiftUI dashboard window ("Hub") for Parla plus a restyle of the
existing HUD pill, both following the visual identity in `docs/plan.md`
(Parla Flow clone spec). Frontend only — no changes to ParlaCore behavior,
no new persistence, no accounts/teams/meetings/scratchpad/connectors (Parla
has no backing for those; they are explicitly out of scope).

## What ships

- **Hub window** — opened from a new **Open Parla…** tray-menu item (first
  item). ~900×620, custom sidebar + content pane, styled with the plan.md
  sand/lavender tokens, light + dark mode. Closing hides the window; the app
  stays menu-bar-only (no dock icon).
- **HUD restyle** — same states/API, redressed as the Flow-bar look: near-black
  capsule, soft purple glow, coral recording dot, white waveform bars.

## Architecture

- New files in `Sources/Parla/Hub/`; `ParlaCore` untouched.
  - `Theme.swift` — color/typography tokens from plan.md (§Visual Identity),
    light/dark via dynamic NSColor providers. System font (SF Pro); no bundled
    third-party fonts.
  - `HubModel.swift` — `@MainActor ObservableObject` bridging existing code:
    loads/saves `settings.json` via `SettingsStore` (debounced whole-file save,
    same as `Set API Key…` today), reads `HistoryStore`, checks the same
    mic/AX/permission and launch-at-login APIs the menu uses. Model download
    state (`modelLoaded`, `downloadProgress`) is pushed in by AppDelegate's
    existing download path.
  - `HubWindow.swift` — window controller (`NSWindow` + `NSHostingView`,
    `isReleasedWhenClosed = false`), sidebar, page routing.
  - `HubPages.swift` — shared row components (section, toggle row, text-field
    row, button row, danger row) and the six pages.
- `main.swift` — adds the menu item and the ~10 lines wiring HubModel to the
  existing download/model-load callbacks.
- Invalid `settings.json`: the hub shows the decode-error banner with an
  "Open file" button and disables all editing — same never-overwrite rule as
  the menu. Settings are re-read every time the window becomes key.

## Pages

1. **General** — permissions card (Microphone / Accessibility status, click
   to open System Settings); whisper model card (loaded state + path, or
   Download button with live progress); Launch at Login toggle; read-only
   shortcut pills (fn = dictate, ⇧+fn = command mode); Open settings file.
2. **AI Cleanup** — provider picker (Anthropic / OpenAI-compatible); model
   field; base URL field (OpenAI-compatible only); API key (secure field,
   placeholder dots when set); key env-var field; short key-resolution note.
3. **Dictionary** — add/remove/edit the `dictionary` spellings list.
4. **Snippets** — add/remove trigger → expansion pairs (`snippets`).
5. **History** — the local 50-entry log: search filter (frontend-only),
   rows with raw/cleaned text, app name, timestamp, per-row Copy,
   Clear History (danger). No per-row delete (HistoryStore has none; adding
   one is a backend change — out of scope).
6. **Data & Privacy** — `historyEnabled` toggle, `restoreClipboard` toggle,
   Clear History, static privacy notes (on-device transcription, secure
   fields never sent to the cleanup LLM, history is local-only).

## Dropped from plan.md

Account, Teams, Plans/Billing, Connectors, MCP, Notetaker/meetings,
Scratchpad, calendar reminders, context-menu palette, notification center,
onboarding tour, mic device picker, shortcut remapping, language pickers,
feature flags — no backing functionality in Parla.

## Testing

UI is presentational over existing tested stores; `swift build` +
existing `swift test` suite must stay green. No new core logic to test.
