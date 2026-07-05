# Parla eval harness

A day-one regression harness that measures Parla's **zero-edit rate** — the
fraction of utterances where the cleaned output needs zero edits versus a
human-written golden — plus ASR and LLM latency percentiles.

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run parla-eval [dir]
```

`dir` defaults to `eval/cases`. It transcribes each `NAME.wav`, runs the same
cleanup pass the app uses (with your real dictionary and snippets from
Settings), and compares against `NAME.golden.txt`.

## Requirements

- The whisper model at `~/Library/Application Support/Parla/models/ggml-base.en.bin`
  (missing → exit 2).
- An Anthropic API key: `ANTHROPIC_API_KEY` env var, or `anthropicApiKey` in
  Settings (missing → exit 2).

## Recording a case

`say` and other TTS **will not do** — the whole point is to exercise real
speech (fillers, self-corrections, trailing-off). Record yourself:

- QuickTime Player → New Audio Recording → export, then convert to 16 kHz mono
  WAV, **or**
- `sox -d -r 16000 -c 1 eval/cases/name.wav` (Ctrl-C to stop).

Then write the expected *cleaned* text — what Parla should have inserted — to
the sibling golden file:

```
eval/cases/name.wav
eval/cases/name.golden.txt
```

Comparison collapses whitespace runs and trims, but is otherwise
case- and punctuation-**sensitive**: zero-edit means zero edits.

## What to collect

Aim for ~50 utterances covering the cases that break naive dictation:

- **Fillers**: "um", "uh", "like", "you know" that should be dropped.
- **Self-corrections**: "send it Tuesday — no, Wednesday".
- **Jargon / names** that live in your dictionary.
- **Numbers**: "six" vs "6", times, versions, money.
- **Code terms**: identifiers, `snake_case`, symbols spoken aloud.

## Output

```
PASS greeting (asr 0.42s, llm 0.81s)
FAIL numbers
  golden: Let's meet at 6.
  actual: Let's meet at six.
zero-edit rate: 1/2 (50%)
latency p50/p95: asr 0.42s/0.61s  llm 0.81s/0.90s
```

Exit codes: `1` if any case failed, `2` if the model or API key is missing,
`0` otherwise (including no cases found).
