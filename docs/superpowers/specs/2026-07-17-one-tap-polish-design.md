# One-tap Polish — design

2026-07-17. Wispr-Flow-style polish: fix a selection's spelling, punctuation,
capitalization, and grammar with one gesture — no speaking. Command mode
without the spoken command.

## Triggers (both)

- **⇧+fn quick tap** (< 200ms, with text selected). Today a short command tap
  is discarded as accidental; command mode has already captured the selection
  at fn-down, so a short release becomes "polish it" instead. Holding ⇧+fn and
  speaking is unchanged.
- **⌃⌘P while idle** — a new `HotkeyMonitor` edge following the existing
  ⌃⌘V (paste last) / ⌃⌘S (scratchpad) chord pattern; swallowed, never reaches
  the front app. The selection is captured at the keypress.

Plain fn short taps stay discarded (accidental Globe press). ⌃⌘P during a
dictation hits the existing any-key-cancels rule, unchanged.

## Flow

Reuses the command-mode transform path with a **built-in instruction**
(`Polish.instruction` in ParlaCore): proofread only — fix spelling,
punctuation, capitalization, grammar; preserve the writer's voice, tone,
wording, meaning, language, and formatting; return unchanged text when nothing
needs fixing. The instruction rides the existing injection-hardened transform
prompt (the selection stays data, never instructions). Dictionary spellings
apply; snippets and app-tone do not. No whisper pass — polish works even with
no model downloaded.

Inherited safety, shared with transforms via an extracted
`applySelectionEdit` helper:

- password fields refuse before anything runs, and again at insert time
- the selection is re-verified before replacing; changed selection → result
  parked in history (or honestly discarded when history is off)
- stale generation → no keystrokes
- empty results and results over the 6× length ceiling are hard failures —
  nothing typed
- terminal newline flattening applies to what is typed

New in the shared helper (both polish and spoken transforms benefit):

- **no-change detection** — result identical to the selection shows
  "✓ No changes" and types nothing
- **modifier wait** — ⌃⌘P's Control/Command may still be held when the LLM
  returns; insertion waits (~1s max, 50ms steps) for a clean keyboard, like
  paste-last does, then re-verifies and types. Timeout → parked in history.

## HUD

`Polishing…` while in flight → `✓ Pasted` / `✓ No changes` / `✓ Saved to
history` / error toast (`Cleanup not configured`, `Polish failed`,
`Select text first`, `No transforms in password fields`).

## Settings

None. Uses the configured cleanup provider; unconfigured cleanup fails fast
with a toast.

## Tests

`HotkeyMonitor` is a pure state machine — new cases covered in
HotkeyTests: ⌃⌘P idle fires `.polish` and is swallowed; ⌃⌘P during push
cancels (existing rule); plain/partial chords ignored. CleanupTests pin the
polish instruction's contract (proofread-only, voice-preserving, routed
through the transform prompt with the selection delimited as data).
