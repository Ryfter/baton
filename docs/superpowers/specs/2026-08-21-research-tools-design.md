# Research instruments — document, OCR, audio, video ingestion

**Date:** 2026-08-21
**Status:** design approved by Kevin (session) — spec pending his review
**Extends:** `tools.yaml` registry; `d091` (`kind: http` is never agentic)
**Does not reopen:** fleet.yaml seating, the Conductor, the Governor, `/baton:route` ranking for LLM rows.

## Why — the gap this closes

`references/tools.yaml` has described a non-LLM capability registry since it was
introduced, and `tools/` can **read** it (`registry.py`), **probe** it
(`doctor.py`) and **print** it (`list.py`). Nothing anywhere **invokes** it —
no call site for `tools_for_capability` exists in `scripts/` or `commands/`.

The consequence is that Baton's founding rule — *use the least costly effective
tool* — is currently a policy with no executor. `deepseek-ocr` is registered
under capability `ocr` and has never been callable. `docling` is registered
under `pdf-extract` and is not even installed (`import docling` →
`ModuleNotFoundError`).

This spec adds the missing runner, then builds a research-ingestion surface on
top of it. The runner is the load-bearing half: every future non-LLM tool
inherits it, and adding one becomes a YAML edit rather than a script.

## Picture

```
/baton:ingest <path-or-url>          ← Layer 2: the research surface
      │
      ├─ sniff source (path | URL) and media class
      │
      └─ capability chain
              │
              ▼
        tools.invoke(capability, payload)   ← Layer 1: the runner
              │
              ├─ filter   enabled + host-compatible rows
              ├─ rank     cost_tier, then priority
              └─ execute  by kind, first success wins, failures fall through
                     │
        ┌────────────┼─────────────┬──────────────┐
        ▼            ▼             ▼              ▼
     python         cli           http        (row disabled)
     docling      wtm/whisper   n8n webhook      skipped
                  yt-dlp        gemini
```

## Layer 1 — `tools/invoke.py`

Single entry point:

```python
def invoke(capability: str, payload: Payload, *, prefer: str | None = None) -> ToolResult
```

`Payload` carries the input path (or URL), the resolved media class, and an
options dict; `prefer` pins a specific row by name, bypassing ranking, and backs
`/baton:ingest --tool <name>`.

### Selection policy

Candidate rows are those with a matching `capability` and `enabled: true`.
They are then ordered:

1. **Host compatibility** — a row whose `host:` does not match the running
   machine is **removed**, never merely deprioritized.
2. **`cost_tier`** — `local` < `free` < `paid`.
3. **`priority`** — optional integer, lower first; the manual override when the
   automatic order is wrong for a particular capability.

The runner tries rows in order and returns the first success. A row that fails
falls through to the next.

### New registry field: `host`

`platform:` in both `fleet.yaml` and `tools.yaml` already means *provider*
identity (`claude | codex | gemini | grok | github | local` — Lever 4).
Overloading it with OS/arch would collide with that meaning, so this spec adds a
distinct field:

```
host:  darwin-arm64 | darwin-x64 | win-x64 | linux-x64 | linux-arm64 | any
```

Absent `host` means `any`. Detection is `platform.system()` + `platform.machine()`
normalized to those tokens.

### Execution by kind

Transports reuse `fleet.yaml`'s proven conventions rather than inventing new
ones — `command_template`, `stdin:`, and `{{...}}` placeholder substitution
behave identically. Placeholders available to tool rows: `{{input}}`,
`{{output}}`, `{{model}}`.

| kind | how it runs |
|---|---|
| `python` | import `entrypoint` and call it as `fn(payload) -> ToolResult` |
| `cli` | render `command_template`, exec, capture stdout (or read `{{output}}`) |
| `http` | POST to `base_url` + `endpoint`; auth header from `api_key_env` |

**`kind: python` needs an adapter, not just a module.** A library's real API is
rarely a one-liner — docling's is
`DocumentConverter().convert(path).document.export_to_markdown()`, which a bare
`module:` path cannot express. So python rows gain an `entrypoint:` field naming
a thin adapter function inside Baton:

```yaml
- name: docling
  kind: python
  module: docling.document_converter      # kept: doctor probes importability
  entrypoint: tools.adapters.docling:extract
```

`module` stays as the *probe* target so `doctor` keeps working unchanged;
`entrypoint` is the *call* target. Adapters live in `tools/adapters/`, take a
`Payload`, return a `ToolResult`, and are where third-party API churn is
absorbed — one small file per library, rather than library shapes leaking into
the runner.

Per `d091`, `kind: http` rows are never agentic — they transform data, they do
not edit files.

### Result and journaling

`ToolResult` carries `ok`, `tool_name`, `output_path` or `text`, `duration_s`,
and `attempts` — the ordered list of rows tried with each failure reason. Every
invocation appends one journal line, so tool runs are as visible as fleet
dispatches.

## Layer 2 — `/baton:ingest`

```
/baton:ingest <path-or-url> [--visual] [--out <path>] [--tool <name>]
```

### Source sniffing

A `://` prefix means URL → run `fetch-media` first to land a local file.
Media class then comes from extension plus MIME sniff.

### Capability chains

| media class | chain |
|---|---|
| document (`.pdf` `.docx` `.pptx`) | `pdf-extract` → markdown |
| spreadsheet (`.xlsx` `.csv`) | see the spreadsheet branch below |
| audio (`.mp3` `.wav` `.m4a`) | `transcribe` → markdown |
| video (`.mp4` `.mkv` `.webm`) | ffmpeg audio-strip → `transcribe`; `--visual` → `video-understand` |
| image (`.png` `.jpg`) | `ocr` |

Output is markdown with provenance front-matter: source, tool that produced it,
timestamp, and duration or page count. Default destination is the KB, so
`/baton:kb-search` finds ingested material without a second step.

Note: images are already readable by an agent's native Read tool. The `ocr` row
exists for *bulk* and *pipeline* use — many pages, or a video's keyframes —
not to duplicate what the agent can already see.

### The spreadsheet branch

Spreadsheet→markdown is lossy in ways the other formats are not: formulas
evaporate, multi-sheet workbooks flatten, and a markdown table of a 10,000-row
sheet costs more context than it saves. So:

- **≤ 200 rows** → markdown table, as expected.
- **> 200 rows** → emit **schema + head/tail sample** as markdown, and write a
  **CSV sidecar** beside it. The agent reads the schema, then queries the CSV.
- **Formulas** → explicitly out of scope for v1. Docling does not preserve them.
  If they later matter, that is an `openpyxl` row under a new capability, not a
  patch to this one.

## Registry additions — `tools.yaml`

| capability | rows, in rank order | notes |
|---|---|---|
| `pdf-extract` | `n8n-pdf-extract` → `docling` | n8n row disabled in the shared seed |
| `transcribe` | `wtm` → `mlx-whisper` (`host: darwin-arm64`) → `whisper-cpp` (`host: any`) | all pin large-v3-turbo |
| `fetch-media` | `yt-dlp` | URL → local media |
| `ocr` | `deepseek-ocr` → `gemini-ocr` | local first, Gemini on failure or hard pages |
| `video-understand` | `gemini-video` | rare; behind `--visual` |

### Transcription seating

Kevin's rule, expressed as data rather than as branching logic: the MLX rows
carry `host: darwin-arm64`, `whisper-cpp` carries `host: any`. On Apple Silicon
the MLX rows survive the host filter and `wtm` (Whisper Turbo MLX) wins on rank.
On Windows, Linux, or an unknown host the MLX rows are filtered out and
`whisper-cpp` is simply what remains — the requested portable default, achieved
with no conditionals.

All three pin **Whisper large-v3-turbo**: first on Kevin's own ASR benchmark
(`github.com/Ryfter/asr-bench` — 8.9% WER and ~65× realtime on a 12-lecture
corpus, winning accuracy *and* speed), and small enough (809M params, ~1.6GB)
that VRAM is not a constraint.

Two precision guards, because Kevin ranked precision above raw speed:

- `wtm --quick` is **off**. The flag is documented as "faster but choppier."
- Weights are **fp16, not 4-bit quantized**. Quantized MLX model repos are the
  quiet precision cost in this stack.

`wtm` is deliberately ~300 lines and therefore lacks the beam search,
temperature fallback and VAD that faster-whisper uses. `mlx-whisper` is the
alternate row for when those decode knobs are wanted on Apple Silicon.

### Gemini seating

Gemini earns rows under **both** `ocr` and `video-understand`, but they are very
different economics and are seated accordingly:

- **OCR** — a page image is a couple thousand tokens; `media_resolution`
  explicitly trades tokens for the ability to read fine text. Good value, seated
  below `deepseek-ocr` on cost and promoted on failure or difficulty.
- **Video** — ~300 tokens/sec at default resolution, ~100/sec at low (audio is
  32/sec of that). A 60-minute lecture is ~1.08M tokens at default, ~360k at
  low. Viable occasionally, ruinous as a default. Hence `--visual` only.

## The workflow tier — n8n, and everyone without it

**n8n needs no new code path.** An n8n workflow exposed as a webhook is
`kind: http`, which the registry already supports. It is a row:

```yaml
- name: n8n-pdf-extract
  kind: http
  enabled: false            # seed default; enabled in the live box-private tools.yaml
  cost_tier: local
  capability: pdf-extract
  base_url: 'http://<tailnet-host>:5678'
  endpoint: /webhook/pdf-extract
  api_key_env: N8N_WEBHOOK_TOKEN
```

Because `cost_tier: local` outranks every paid row, it wins automatically where
it is enabled. Where n8n is absent the row is disabled — or `doctor` marks it
unreachable — and the runner falls through to calling docling directly.
**The "must also work without n8n" requirement therefore costs zero branches**,
and mirrors how the seed already ships disabled OpenRouter rows. Make and Zapier
drop in identically; they are webhooks too.

### Two constraints specific to Kevin's instance

The host is a Raspberry Pi on his tailnet (also published at
`https://n8n.3dmkf.com/` — verified reachable, HTTP 200 in 178ms, `/healthz` OK).

1. **Documents yes, media no.** The Pi has no GPU and no MLX, so transcription
   there would be far slower than on the local M4. Tailscale removes the
   *bandwidth* objection to sending it large files; the *compute* objection
   stands on its own. n8n rows are therefore seated under document capabilities
   only, never in the media chain. `priority:` is the knob if that proves wrong.
2. **Use the tailnet address, and authenticate.** The public hostname resolves
   from anywhere, which makes an unauthenticated `/webhook/...` path an open
   door. Pointing `base_url` at the tailnet keeps traffic off the public
   internet, and the `api_key_env` header is defense in depth rather than the
   only control. The token stays box-private and never enters the shared seed.

## Installs required

| tool | install | status |
|---|---|---|
| docling | `uv pip install docling` | registered, **not installed** |
| whisper-turbo-mlx (`wtm`) | `uv pip install whisper-turbo-mlx` | not installed |
| mlx-whisper | `uv pip install mlx-whisper` | not installed |
| whisper.cpp | `brew install whisper-cpp` + large-v3-turbo weights | not installed |
| yt-dlp | `brew install yt-dlp` | not installed |
| ffmpeg | — | **already present** |

## Error handling

A failed row falls through to the next candidate. When every row for a
capability fails, the error names each row tried and why — the same detail
`doctor` reports. Empty markdown is never written as though it succeeded; a
zero-byte or whitespace-only extraction is a failure, not a result.

## Testing

The selection policy is pure logic over fabricated rows, so `tools/tests/test_invoke.py`
covers ranking, host filtering, fall-through, and the all-rows-failed path
**on a machine where none of these tools are installed**. That is the point:
the rules are testable without the toolchain.

Live execution gets a separate integration test, skipped unless the tool is
present. The spreadsheet threshold branch is unit-tested at 200 rows either side.

## Build order

Sequenced by Kevin's stated usage frequency, not by architectural tidiness:

1. `tools/invoke.py` + `host` field + tests — nothing else can land first.
2. `fetch-media` + `transcribe` rows — YouTube audio, the most-used path.
3. `ocr` rows — second most used.
4. `pdf-extract` rows + docling install; `/baton:ingest` document chain.
5. Spreadsheet branch.
6. `video-understand` — rarest, ships last.
7. n8n rows — additive, once the direct paths are proven.

## Delegation

Implementation goes to the fleet: **ox-alpha** (opencode) writes, **Grok**
reviews, **Kiro** as a third opinion where it earns its place, Claude integrates
and runs the tests.

⚠️ The `opencode` row is pinned to `opencode/big-pickle` and annotated in
`~/.baton/fleet.yaml:274` as **expiring ~2026-08-27**. That row also claims
`[code-gen, reasoning]` only — `review` is deliberately unclaimed, because its
headless output may carry ANSI codes that break strict-JSON parsing. Hence Grok,
not opencode, on review.

## Open items

- The n8n webhook workflows themselves must be authored on the Pi; this spec
  covers only Baton's side of the contract.
- `asr-bench` is faster-whisper/CUDA-based and cannot currently score MLX
  engines. Adding MLX engines to it would let Kevin verify the `wtm` seating
  empirically rather than by reputation. Separate repo, separate work, noted
  here only because it would close the loop.
