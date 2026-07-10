# Parla — Architecture

Two designs were on the table. Both reviewed; verdict and merged plan below.

## The two candidate designs

**A. Local-first (my original proposal)** — everything on-device: hotkey →
mic → whisper.cpp → LLM cleanup call → paste. No backend.

**B. Full cloud platform (your findings)** — streaming gateway, ASR router,
GPU fleet, personalization engine, sync, teams, SSO/SCIM, analytics — an
incumbent-scale production platform.

## Review verdict

Neither is wrong; they're different *stages*. Building B first is the classic
mistake — it's ~10 services and months of infra before the first word is
dictated. Building only A caps you at a single-user tool.

**Corrections to design B (your mermaid flow):**

1. **Personalization placement.** You had ASR → LLM → Personalization Engine →
   insertion. Wrong order: dictionary terms, snippets, style, and app context
   must be *inputs to the LLM prompt*, not a post-pass. A post-pass doing
   string replacement re-breaks grammar the LLM just fixed ("Kubernetes" vs
   "kubernetes" mid-sentence, snippet expansion inside a formatted list).
   Correct flow: **context builder → (transcript + context) → LLM → insertion**.
2. **ASR router is premature.** Routing "by language, accent, latency, load,
   model version" is a v3 concern. Whisper-family models are multilingual;
   one model + one fallback vendor covers v1–v2.
3. **Kafka/ClickHouse/K8s GPU pools** are listed as core; they're not needed
   until you have paying teams. Postgres + one inference box goes a long way.
4. Otherwise design B is correct as the *end state* — the service breakdown,
   data model, and hard-problems list are right, and "the hard part is
   insertion, not recording" is exactly right.

**Corrections to design A (mine):**

1. "No backend at all" is only true if cleanup is also local. If v1 calls a
   cloud LLM, the transcript (though not the audio) still leaves the device.
   Be explicit about it in the UI.
2. Local ASR quality: whisper.cpp `large-v3-turbo` on Apple Silicon is fast
   and good, but fine-tuned cloud models will beat it on names/jargon.
   The personal dictionary compensates — inject dictionary terms as a Whisper
   `initial_prompt` AND into the LLM cleanup prompt.
3. Push-to-talk means no VAD needed for v1 (the hotkey IS the voice-activity
   signal). VAD only matters for hands-free/toggle mode later.

## Recommended architecture (phased)

### Phase 1 — local-first Mac MVP (the actual next step)

```
┌────────────── macOS menu-bar app ──────────────────┐
│                                                     │
│  Global hotkey (CGEventTap)  — hold to talk         │
│      │ down                                         │
│      ▼                                              │
│  AVAudioEngine mic capture (16 kHz mono PCM)        │
│      │ up                                           │
│      ▼                                              │
│  whisper.cpp (Metal, large-v3-turbo)                │
│    initial_prompt = personal dictionary terms       │
│      │ raw transcript                               │
│      ▼                                              │
│  Cleanup LLM (one API call; local model later)      │
│    prompt = transcript + dictionary + snippets      │
│           + active app name (from AX API)           │
│      │ polished text                                │
│      ▼                                              │
│  Insertion: CGEvent Unicode keystrokes              │
│    no clipboard — transcripts stay in-app;          │
│    failures recoverable from local history          │
└─────────────────────────────────────────────────────┘

Local state: JSON/SQLite — dictionary, snippets, settings, history.
Permissions: Microphone + Accessibility (+ Input Monitoring if needed).
```

Latency budget: hotkey-up → text inserted in <2s. Whisper turbo does ~10s of
audio in well under 1s on M-series; the LLM call is the long pole (~0.5–1s
with a fast model). Good enough without streaming.

The upgrade when it isn't: **transcribe while the user is still talking** —
run whisper.cpp incrementally on chunks during capture, so at hotkey-up the
transcript is already done and only the LLM pass remains. This is how
cloud incumbents make two model calls feel instant; it works identically
on-device. (Phase 2+ optimization; for the Phase 3 cloud ASR path, also
compress audio on the wire — Opus, not raw PCM.)

What Phase 1 deliberately skips:
- streaming ASR / live partials — add when the pause after hotkey-up feels slow
- VAD — add with hands-free toggle mode
- Windows client — add after Mac UX is proven
- any backend — add in Phase 3

### Phase 2 — the product features (still no backend)

- **Personal dictionary UI** + auto-learn from user's post-insertion edits
  (diff AX field content shortly after insert — this is the
  feedback loop, all local).
- **Snippets** — spoken cue → expansion, resolved in the LLM prompt.
- **Command Mode / Transforms** — read selected text via AX API, apply spoken
  instruction, write back. Same pipeline, different prompt.
- **App-aware style** — active app bundle ID → tone hint (Slack casual,
  Mail formal, IDE code-aware camelCase/snake_case).
- **History + retry/copy fallback UI.**
- **Local cleanup model option** (Ollama, ~3B) → true zero-network mode.
  This is the differentiator cloud-only incumbents structurally can't offer:
  their transcription always leaves the device.

### Phase 3 — backend, only when multi-device/teams demand it

Add services in dependency order, not all at once:

```
Client ──TLS──► API gateway (auth, rate limit)
                  │
                  ├─► Sync service ── Postgres
                  │     dictionary, snippets, settings, history(opt-in)
                  │
                  ├─► Cloud ASR (optional per-user route)
                  │     GPU box w/ faster-whisper; vendor fallback
                  │     streaming (WebSocket) once latency matters
                  │
                  ├─► Cleanup LLM proxy (server-held API keys,
                  │     zero-retention vendor agreements)
                  │
                  └─► Billing (Stripe) · Teams (shared dict/snippets)
```

- Postgres for accounts/settings/dictionary; Redis for sessions; object
  storage only if users opt into history. Audio ephemeral by default —
  zero-retention is the *default*, not a toggle (beats incumbent posture).
- Privacy Mode enforced at the request layer (gateway strips
  retention/training flags), org-enforceable for enterprise.

### Phase 4 — enterprise (only with a paying org waiting)

SSO/SAML, SCIM, org policy enforcement, audit logs, usage dashboards
(plain Postgres aggregates until scale forces ClickHouse), SOC 2 track.

## Eval infrastructure (start in Phase 1, tiny)

Design B is right that evals matter from day one — but day-one evals are a
script, not a pipeline:
- fixed set of ~50 recorded utterances (fillers, self-corrections, jargon,
  numbers, code terms) → run through pipeline → diff against golden outputs
- track: zero-edit rate, WER on names, latency p50/p95
- grow into a real regression suite when models/prompts start changing weekly

## Hard problems (ranked by when they bite)

1. **Insertion reliability across apps** — Phase 1, day one. Secure input
   fields, Electron apps, terminals all behave differently. Every transcript
   is kept in local history as the escape hatch (no clipboard involvement).
2. **Self-correction handling** ("at 5… actually 6") — prompt engineering +
   eval set; the LLM does this well if explicitly instructed.
3. **Latency feel** — Phase 1–2. Push-to-talk + turbo model is fine; streaming
   is the Phase 3 upgrade.
4. **Dictionary accuracy without retraining** — initial_prompt + LLM context
   covers most of it.
5. **Permission loss recovery** (macOS revokes AX on updates) — detect and
   re-prompt gracefully.
6. Multilingual routing, model regressions at scale, enterprise trust —
   Phase 3+.

## Build order

1. Mac MVP: hotkey → whisper.cpp → LLM cleanup → paste. (Phase 1)
2. Dictionary, snippets, history, retry/copy fallback. (Phase 2)
3. Explicit privacy story: local ASR always; optional local LLM = zero network.
4. Command Mode / transforms on selected text.
5. Backend + sync + billing when a second device/user needs it.
6. Teams, then enterprise, each only when demand exists.
7. Eval script from week one; grow it with the product.
