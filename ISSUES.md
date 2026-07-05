# Parla — Reported Issues Log

User-reported issues, their root causes, and current status. (2026-07-05)

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

## 5. Text not streaming in real time into the focused textbox — PARTIALLY FIXED
- Works: streaming appends in real time (~1 word/second cadence, verified in
  logs and on screen in user's session 20:47).
- Root causes found and fixed along the way: focus detection said "none" in
  Electron/web apps (added app-level AX fallback + accessibility wake-up
  flags); whisper `[BLANK_AUDIO]` hallucination markers were typed as text
  (now stripped).
- STILL OPEN: in the user's chat box, mid-stream revisions and the final
  replacement don't apply (see #6/#7 trade-off) — text appears but stops
  updating, final lands in clipboard instead of the box.

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

## 7. "Now it only writes to the clipboard" — OPEN (direct consequence of #6)
In the user's chat box, verification fails (field is opaque to AX and the
select-back check hasn't been confirmed working there), so the safety rule
routes the final cleaned text to the clipboard instead of replacing in-place.
The select-back-and-verify fallback (commit 28db0a6) is built for exactly
this but is NOT yet proven in the user's chat app — needs one real test.
Diagnostics logging is in place (`finish path: ...` lines) to show which
path fired.

## Next steps
1. User tests current build in the real chat box; read `/tmp/parla-stderr5.log`
   `finish path` lines to see whether select-verify works there.
2. If select-verify fails in that app: log WHY (selection unsupported vs copy
   timeout vs text mismatch) and decide per-app strategy — possibly a
   user-facing setting: "replace mode: safe / aggressive" where aggressive
   trusts counts (old behavior) for apps the user vouches for.
3. Identify the actual chat app (which app is it?) to test against directly.
