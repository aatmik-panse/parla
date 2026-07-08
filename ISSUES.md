# Parla — Reported Issues Log

User-reported issues, their root causes, and current status. (2026-07-05, updated 2026-07-08)

## 1. "I am not able to use the app. I wrote the key in .env" — FIXED
The app never reads `.env`, and GUI apps don't inherit shell env vars.
Groq key + provider block written into `~/Library/Application Support/Parla/settings.json`.
Verified live: Groq answers with our exact request shape; eval passes 2/2.

## 2. Move hotkey from Right Option to fn/Globe — FIXED
HotkeyMonitor now watches keyCode 63 + `.function` flag. Confirmed firing
(fn down/up in logs from real keypresses).

## 3. "There should be some UI when I use the app" — FIXED
Floating HUD pill: Listening… + live waveform (driven by real mic RMS levels,
no mock), Cleaning…, ✓ Pasted / ✓ In clipboard / error states. Confirmed on
screen.

## 4. Permissions repeatedly "not working" after every fix — FIXED (root cause)
`make-app.sh` signed ad-hoc → new code hash every rebuild → macOS silently
invalidated Mic/Accessibility grants each time we shipped anything.
Now signs with a stable designated requirement (`identifier "com.parla.app"`);
verified identical across rebuilds. Grants survive rebuilds from now on.

## 5. Text not streaming in real time into the focused textbox — FIXED
- Works: streaming appends in real time (~1 word/second cadence, verified in
  logs and on screen in user's session 20:47).
- Root causes found and fixed along the way: focus detection said "none" in
  Electron/web apps (added app-level AX fallback + accessibility wake-up
  flags); whisper `[BLANK_AUDIO]` hallucination markers were typed as text
  (now stripped).
- RESOLVED by the instant-finalize rework (2026-07-08): fn-up now lands the
  raw transcript immediately through the same verified paths used for
  streaming — AX-verified erase+retype, select-back-and-verify for AX-opaque
  fields, or clipboard fallback only when neither can be proven safe. The
  cleaned version then swaps in behind it with its own verification, so a
  chat box that used to stop updating mid-stream now always ends with either
  the raw or cleaned text landed and verified in the box, or a distinct HUD
  state ("✓ cleaned in clipboard") when it genuinely couldn't be proven safe
  to touch the field again.

## 6. "It removed text that it didn't write" — FIXED (with a trade-off)
Blind backspace counts could eat pre-existing text when the app dropped a
synthetic keystroke or autocorrected. Now every erase is verified first:
- AX path: read the field's text+cursor, erase only if the tail exactly
  matches what Parla typed.
- Opaque fields: select-back (⇧←×N) + ⌘C + compare; replacement types over
  the verified selection only.
- If neither verifies: never delete — append-only streaming, final to
  clipboard.
Guarantee now: Parla cannot delete text it didn't write.

## 7. "Now it only writes to the clipboard" — ROOT CAUSE FOUND, PATCHED
Reproduced from `/tmp/parla-stderr5.log`: live append worked, but finalization
logged `finish path: unverified, clipboard only` even though `focus=1`. Root
cause: Parla enabled live streaming for fields that merely looked editable via
AX, but whose text/cursor could not be read back for safe final replacement.
That created a bad state: draft text had already streamed into the box, cleanup
could not verify what to replace, and the safety fallback copied to clipboard.
Patch: live streaming now starts only when final replacement is AX-verifiable;
opaque focused text boxes skip streaming and use the final focused paste path.
Clipboard-only is reserved for no focused element.

## 2026-07-08 improvements
- whisper.cpp upgraded to v1.9.1 (vendored xcframework), restoring Metal GPU transcription; `make-app.sh` bundles `whisper.framework` into the app.
- Instant finalize: fn-up lands the raw transcript immediately through the verified paths, then the LLM-cleaned version swaps in behind it via a diff; new HUD states for each outcome (Transcribing…, ✓ · polishing…, ✓ Pasted, ✓ In clipboard, ✓ cleaned in clipboard, ✓ raw (cleanup failed), ✕ Cancelled).
- Streaming windowed past ~15s: a confirmed prefix is frozen at the nearest quiet point so re-transcription passes stay O(tail), not O(whole recording).
- Hotkey ergonomics: taps under 200ms discard silently, any real keypress while fn is held cancels and undoes streamed text, and start/finish/cancel get distinct system sounds.
- Safety guards: password fields go on-device-transcript-to-clipboard-only (never pasted, never sent to cleanup); terminal apps get newline runs flattened so multi-line text can't execute per line; sub-0.4s or silent audio is skipped instead of transcribed (whisper hallucination guard).
- Failure visibility: broken settings.json is surfaced in the menu instead of being silently reset; menu shows live Mic/Accessibility permission status with click-to-fix; missing model gets a one-click base.en download with progress in the status item.
- Local dictation history: last 50 dictations (raw + cleaned + app) saved to history.json; menu gains Paste Last Dictation, a Recent submenu, and Clear History.
- Papercuts: HUD now shows on the screen you're actually dictating into; Launch at Login toggle; `liveStreamingEnabled` setting to disable mid-stream retyping; opt-in `restoreClipboard` to put the prior clipboard back after a verified in-field landing.
- Command mode: hold ⇧+fn with text selected, speak an edit instruction, release — the selection is transformed and pasted over itself, with a hard failure (nothing pasted) on any error and a clipboard fallback if the selection changed underneath it.

## Next steps
1. Real-world testing of the instant-finalize + swap flow across more apps (Electron chat apps, terminals, browser text areas) — confirm the raw-then-cleaned handoff feels instant and the swap lands correctly, not just in logs.
2. Exercise command mode (⇧+fn) in daily use: verify transform quality, the selection-changed clipboard fallback, and that failures never leak the spoken instruction.
3. Verify the failure-visibility paths for real: a genuinely corrupt settings.json, a revoked permission, and a from-scratch model download.
4. Live with `liveStreamingEnabled`/`restoreClipboard` toggled both ways to sanity-check the opt-in defaults feel right.
