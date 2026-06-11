# Gauntlet — local-model testing suite (design)

**Status:** spec'd 2026-06-11; **build deferred** (Kevin: "spec out the testing interface. That will be built out at a later date.")
**Working title:** *Gauntlet* (a gauntlet of trials — placeholder, Kevin renames at build time; precedent: his ASR-benchmark app)
**Relationship to Baton:** standalone app, own repo (the Grimdex move). Baton CONSUMES its scorecards; Gauntlet never routes work. Sibling doc: the models-as-tools requirements list (memory `project_models_as_tools_vision`, 15 requirements, 2026-06-11 design spurt).

## Purpose

Empirically answer, while the boxes are idle: **which local model is best at which job, at what resource cost** — so registry claims, culling recommendations, and best-of-breed slots rest on measured data instead of reputation.

## Non-goals

- No routing, no registry claims, no model install/delete (Baton's advisor recommends; the human acts).
- No model management (loading/unloading beyond what a test run needs).
- Not Baton-specific: any project (or student) can point it at an endpoint.

## Decisions made

1. **Standalone app, own repo** — like Grimdex: engine public-ready, results data portable. Baton lists it in `tools.yaml` (a tool whose capability is rating tools) and imports its scorecards.
2. **Server-agnostic via OpenAI-compatible HTTP** — the only hard requirement on a target is a `/v1/chat/completions` (and `/v1/embeddings` for embedders) endpoint: LM Studio, Ollama, wraith2 over Tailscale, llama.cpp server, anything. Optional enrichment adapters (LM Studio native `/api/v1/models` for capabilities/quant/context metadata; `ollama show`) when available.
3. **Implementation language: Python** (proposed; revisit at build) — HTTP+JSON heavy, cross-platform, teaching-friendly, and Baton already carries a Python toolchain. Alternative considered: PowerShell (fleet libs exist, but the app must outlive Baton's stack choices).
4. **Deterministic checks beat judges wherever possible.** Scoring methods per test, in preference order: exact/regex match → parse-and-validate (JSON schema, compilable code, conventional-commit format) → LLM judge with a per-battery rubric. Judges are pluggable, must be non-reasoning strict-JSON models, and judge verdicts record WHICH judge scored (a judge is itself a model under test elsewhere — never let it grade its own family blind).
5. **Resumable, checkpointed runs** — one model × battery cell at a time, results appended immediately; a crashed overnight run resumes where it stopped. VRAM-aware sequencing: broad models load one at a time; tight tools may co-reside (per the two-class policy).
6. **Scorecard is the contract.** Canonical JSON + human-readable Markdown report. Consumers (Baton, humans, students) only ever depend on the JSON shape.
7. **Keep-list respected** — models tagged `personal/keep` (e.g. the guardrail-removed teaching models) are skipped entirely unless explicitly named on the command line.
8. **Frontier baseline is opt-in and sampled** — a small per-capability sample against a frontier API measures the local-vs-frontier gap (the "permanent $0 route" detector). Never runs by default; it costs money.

## Architecture

### G.1 Targets — `targets.yaml`

```yaml
targets:
  - name: firefly-lmstudio
    base_url: http://localhost:1234
    api: openai            # /v1/chat/completions, /v1/embeddings
    enrich: lmstudio       # optional: /api/v1/models metadata (context, quant, reasoning flag)
    box: firefly           # joins the infra inventory (VRAM budget, usage classes)
  - name: wraith2-ollama
    base_url: http://100.115.71.9:11434
    api: openai
    enrich: ollama
    box: wraith2
models:                    # optional explicit roster; default = discover from target
  - { target: firefly-lmstudio, id: 'phi-4', context: 8192 }       # a LOAD PROFILE: model @ context
  - { target: firefly-lmstudio, id: 'qwen/qwen3-coder-30b', context: 32768 }
keep_list: [ 'gemma-*heretic*', '*swahili*' ]   # glob patterns; skipped unless named explicitly
```

A **load profile** (model @ context) is the unit under test — the same model at 8K and 128K is two rows, because VRAM = weights + KV(context) and quality can differ at depth.

### G.2 Batteries — `batteries/<capability>.yaml`

One file per capability (the taxonomy's empirical mirror): `commit-msg`, `extract-json`, `summarize-short`, `summarize-long`, `synthesize`, `write-personal`, `write-scientific`, `write-formal`, `code-gen`, `code-transform`, `ocr` (file inputs), `embed` (retrieval eval), `judge` (meta: can this model grade?), `context-depth` (needle-at-depth — turns advertised context into *effective* context curves).

```yaml
capability: extract-json
context_floor: 4096          # load profiles below this never run this battery
cases:
  - id: invoice-01
    prompt_file: cases/extract-json/invoice-01.txt
    scoring: json-schema     # deterministic
    schema_file: cases/extract-json/invoice-01.schema.json
  - id: messy-table-03
    scoring: judge
    rubric: "Score 0-1: completeness of extracted fields, correctness of values, no invented data."
weights: { quality: 1.0 }    # per-battery scoring knobs
```

### G.3 Runner

`gauntlet run [--targets ...] [--batteries ...] [--models ...] [--resume <run-id>]`
- Sequences cells (load profile × battery), respecting box VRAM budgets and the tight/broad classes; records per-cell: pass-rate / mean quality, latency p50, tokens/sec, configured context, observed footprint (enrichment APIs where available), errors.
- `gauntlet baseline --capability X --sample N` — the opt-in frontier comparison.
- Overnight use = OS scheduler (Windows Task Scheduler) invoking `gauntlet run` inside the idle window; Gauntlet itself stays scheduler-agnostic.

### G.4 Scorecard — the contract

`scorecards/<date>-<run-id>.json` (canonical) + `.md` (report):

```jsonc
{ "run": { "id": "...", "date": "...", "gauntlet_version": "..." },
  "cells": [ { "model": "phi-4", "target": "firefly-lmstudio", "context": 8192,
               "capability": "extract-json", "quality": 0.91, "pass_rate": 0.86,
               "latency_p50_s": 2.1, "tokens_per_s": 38, "judge": "phi-4@wraith2|null",
               "cases": 14, "errors": 0 } ],
  "context_depth": [ { "model": "...", "advertised": 262144, "effective_90pct": 49152 } ],
  "baseline_gaps": [ { "capability": "commit-msg", "local_champion": "tavernari",
                       "frontier": "claude", "gap": 0.03 } ] }
```

Baton's import (models-as-tools slice, separate spec) maps scorecards → claims, economy/champion picks, culling candidates, and $0-route declarations. Reports double as teaching artifacts (the small-vs-frontier story, shown not told).

### G.5 Errors

Unreachable target → cells skipped + counted, run continues. Model fails to load / OOM → cell errored with reason, never aborts the run. Judge unavailable → judge-scored cases marked `unscored` (NOT silently heuristic — a scorecard must never overstate confidence). Malformed battery file → named loudly at startup, run proceeds with the rest.

## Requirements traceability (Kevin, 2026-06-11 spurt)

Overnight/idle autonomous testing (req 4) → G.3 + OS scheduler. Rate models per task (4, 5) → G.2/G.4. Quality-per-resource, bars not maxima (6) → scorecard carries quality × latency × footprint; consumers apply bars. Champions protected, near-peer culling (7) → consumer-side, fed by G.4. Context as fitness axis + effective context (8) → context floors, load profiles, `context-depth` battery. Keep-list (9) → decision 7. BoB-local + frontier gap (10) → `baseline_gaps`. Load-profile VRAM (11) → G.1. Writing registers (12) → G.2 batteries. Separate app (13) → the whole document. Tight/broad classes (14) + wraith2 as tight host (15) → G.1 `box` join + sequencing.

## Out of scope (this app, any version)

Routing/dispatch (Baton), fine-tuning (interesting later: the commit-LoRA), model downloads, GUI (reports are files; a dashboard could read scorecards someday).

## Build plan

Deferred by design. When picked up: own repo (`Ryfter/gauntlet` or renamed), own brainstorm-refresh → plan → build cycle; Baton's models-as-tools slice can ship its registry/taxonomy half first and consume hand-made scorecards until Gauntlet exists.
