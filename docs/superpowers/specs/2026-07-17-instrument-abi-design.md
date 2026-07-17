# Instrument ABI — Python/HTTP instruments actually routable (#92, d086 node #4)

**Date:** 2026-07-17 · **Issue:** #92 · **Spine:** d086 (Project #5, umbrella #97)
**Origin:** Codex's 2026-07-13 audit caught the CLI-only dispatch gap; pre-brief
`Grimdex projects/baton/notes/2026-07-16-instrument-abi-prebrief.md`.

## Problem

Baton's thesis is "add any instrument: drop in a row, it becomes routable." Structurally
that only holds for CLI instruments today:

1. **Auto-routing skips non-CLI tools.** `routing-dispatch.ps1` (`Invoke-RoutedCandidate`)
   hard-skips any `tools.yaml` candidate with `kind -ne 'cli'` — so `docling`
   (`kind: python`) can be listed but never dispatched.
2. **HTTP fleet rows need a hand-written PowerShell hatch each.** `Invoke-Fleet` requires
   `scripts/fleet/<name>.ps1` defining `Invoke-<PascalName>` for every `kind: http` row.
   The three existing hatches (lm-studio, lm-studio-small, ollama-box2) are near-identical
   OpenAI-compatible POSTs — copy-paste ABI, not a declared one.
3. **HTTP responses discard native token counts.** The hatches drop the response `usage`
   block, so local models journal `tokens_basis: estimate` even though the server reports
   exact counts. #93 (bakeoff) needs exact local numbers to be honest.

## The ABI, stated once

Two contracts (declaration + invocation), one return row. Every transport MUST normalize to:

```
@{ stdout; stderr; exit_code; duration_s; tokens; tokens_basis ('exact'|'estimate') }
```

— exactly what the fleet journal, usage classifier (d083), telemetry, and graders already
consume. Nothing downstream changes.

## Design (slice 1)

### 1. Generic OpenAI-compatible HTTP invoker (fleet rows)

New `Invoke-FleetHttpChat -Provider -Prompt -Model` in `fleet-lib.ps1`:

- POST `{base_url}/v1/chat/completions`, model resolution exactly as today
  (explicit arg > pinned `model_default` ≠ 'auto' > first listed model, per d043).
- **Extract native usage:** when the response carries `usage.total_tokens` (or
  prompt+completion), return `tokens` with `tokens_basis = 'exact'`. Missing usage block →
  omit fields and let the existing `Get-FleetTokenUsage` estimate fallback run (unchanged).
- `Invoke-Fleet` dispatch order for `kind: http`: **hatch file wins if present**
  (`scripts/fleet/<name>.ps1` stays the per-provider escape hatch/override), else the
  generic invoker. This is fully backward compatible; no fleet.yaml change is required
  to adopt it.
- Delete the three redundant hatches (`lm-studio.ps1`, `lm-studio-small.ps1`,
  `ollama-box2.ps1`) so those rows ride the generic path and start reporting exact tokens.
  `stub-http.ps1` stays (test fixture / hatch-mechanism regression coverage).

### 2. tools.yaml routability: `python` and `http` kinds

- `Invoke-Tool` gains `kind: python`: identical to `cli` execution (command_template +
  stdin/positional prompt) — the kind is a *declaration* distinction (interpreter-hosted,
  useful for future venv/env handling), not an execution one, so the implementation is
  shared with a widened guard.
- `Invoke-Tool` gains `kind: http`: `base_url` + optional `endpoint` (default
  `/v1/chat/completions`), same generic POST + usage extraction as §1 (shared helper).
- The `Invoke-RoutedCandidate` gate flips from "only cli" to a **supported-kinds set**
  (`cli`, `python`, `http`, `stdio-json`); anything else still skips with the same loud
  journaled reason. The skip mechanism is proven — only the set widens.

### 3. `stdio-json` transport (fleet + tools) — the extensibility story

Any executable speaking **one JSON request on stdin, one JSON response on stdout**:

```
request:  { "prompt": "...", "model": "...", "tier_args": "..." }
response: { "output": "...", "exit_code": 0, "tokens": 123, "tokens_basis": "exact" }
```

- Generic invoker: write request to a temp file (965-byte rule — never inline), pipe to
  the process, parse one JSON object from stdout, normalize to the return row. Malformed
  JSON / nonzero exit → honest failure row (`exit_code`, stderr preserved) — the d083
  classifier sees it like any other failure.
- Same shape as the codex app-server probe pattern (d090), and model-agnostic per the KB
  standing order: adding an instrument in any language = a script + a row, zero Baton edits.

### 4. Declaration fields (additive, no schema rewrite)

fleet.yaml / tools.yaml rows may declare (all optional):

- `max_prompt_bytes` — pre-flight home for the #104 context_overflow lesson (the 33KB-ok /
  50KB-dies local-lens ceiling). **Enforced at dispatch in this slice**: prompt exceeding a
  declared ceiling → skip with a loud `prompt_too_large` reason *before* wasting the call;
  journaled like any skip. Undeclared → no check (today's behavior).
- `probe:` — declaration slot for d090 probe adapters (`codex-app-server` | absent). Wiring
  beyond what Layer 2 already does is out of scope; this just gives it a declared home.
- `agentic:` — declared but **`agentic: true` remains CLI-only** (d009): the executor
  refuses http/stdio-json for agentic (file-editing) work. Fork F1 default — giving an
  HTTP instrument file-edit powers needs a harness design of its own, later.

### Non-goals (explicit)

- No agentic dispatch over http/stdio-json (F1, d009).
- No capability auto-discovery handshake (F3) — static declaration only; the
  start-of-run availability sweep stays a separate idea.
- `baton_mcp` stays a front door for other agents, **not** an instrument transport.
- No new fleet.yaml rows shipped (box-private; seed/examples use placeholder hosts only).

## Consequences

- #93 bakeoff becomes honest: local models report exact tokens.
- #104 gets its declaration home (`max_prompt_bytes`) and a pre-flight guard.
- Three copy-paste hatches collapse into one tested invoker; hatch mechanism retained
  as the escape valve.
- The "add any instrument" thesis holds structurally: any language, no Baton changes.

## Testing (hermetic — never real ~/.baton, ~/.claude, or live servers)

- HTTP invoker: local mock listener fixture (existing pattern) — usage-block present →
  exact; absent → estimate fallback; non-200 / timeout → failure row.
- stdio-json: fake-child executable fixture (pattern from usage-probe tests) — happy path,
  malformed JSON, nonzero exit, oversized prompt via temp file.
- Routing gate: supported-kinds set admits python/http/stdio-json, still skips unknown
  kinds loudly; `max_prompt_bytes` skip row asserted.
- Regression: hatch-override precedence (stub-http), cli path untouched, journal row
  shape unchanged (5-field consumer test stays green).

## Sizing

One Codex build (§1+§2+§4 core), stdio-json (§3) in the same PR — generic invoker is
~40 lines with the request-file pattern already proven by the d090 probe. Review per the
conductor playbook: Grok adversarial + chunked local lenses (<35KB), independent gate.
