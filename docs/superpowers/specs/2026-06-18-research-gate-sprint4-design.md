# Sprint 4 — Research Gate (design)

**Status:** approved 2026-06-18
**Roadmap:** Baton v2 economic-conductor MVP, Sprint 4 of 7. Follows Sprint 1
(Triage Agent), Sprint 2 (Usage Governor), Sprint 3 (GitHub Projects sync).
**Mantra:** *Before you build, ask if it already exists. Cheap model + real evidence beats an expensive guess.*

## 1. Scope

Given a task description, produce a structured **build / adopt / adapt / inconclusive**
verdict — the cheapest spend that prevents the most expensive waste (building a
subsystem that already exists; the "Doc2MD" trap). The Gate consumes Triage's
`research_required` signal and grounds a cheap synthesis model in **real evidence**
(local tool registry + the prior research ensemble + KB + optional live web/registry
search), then emits an advisory verdict. It is **recommend-only**, never blocking —
consistent with Triage's posture.

A new operator surface `/baton:research-gate` exposes one action: classify a task into
a verdict and (when a job is active) write the memo into that job's `research` phase.

### Relationship to the existing `/baton:research` ensemble

`/baton:research` already exists and is a **different tool**: an open-ended fleet
*ensemble* that fans a question out to a roster of providers, prepends KB hits, and
writes `synthesis.md` into `jobs/<id>/phases/research/ensemble-<ts>/`. That is
**evidence gathering**. The Research Gate is the **decision** step that reads the latest
such synthesis (when present) and distills a structured verdict. Clean split:
the ensemble *gathers*, the Gate *decides*. Both live in the `research` phase.

### Out of scope (deferred, named so the boundary is explicit)
- **Package existence-verification.** `-Deep` surfaces candidates via one search round;
  it does NOT run an agentic "does `npm view X` 404?" verify loop. The model reasons over
  the evidence; the human verifies before adopting. A Sprint-4.1 add if wanted.
- **Auto-chaining from Triage.** Triage emits `research_required:true`; auto-invoking the
  Gate on that signal is deferred. This sprint wires the Gate to the job `research` phase
  and leaves it operator-invoked.
- **The `/baton:go` Maestro.** The natural-language plan-then-execute front door is a
  separate initiative (its own brainstorm → spec → plan), not part of Sprint 4. The Gate's
  `-Json` output is one of the tools that Maestro will later sequence.
- **Registering the GitHub model allotment as a worker** (`gh models run`). Still Sprint 6
  (Worker Adapter). The Gate uses whatever workers the fleet offers.

## 2. Decisions

- **d-rg-1 — separate command; gather/decide split; the Gate reads the ensemble.** The Gate
  is `/baton:research-gate`, distinct from the `/baton:research` ensemble. It reads the
  latest ensemble `synthesis.md` in the active job's `research` phase as one evidence source.
  (Chosen over folding a `--gate` flag onto `/baton:research`, which would overload one
  command with two very different output shapes.)
- **d-rg-2 — cheap-model floor + live-evidence grounding ("cheap model + good context").**
  Synthesis routes through `Select-Capability -Capability research` preferring a cheap tier
  (Haiku-class), escalating to a champion on low confidence — exactly Triage's pattern.
  Accuracy comes from grounding the cheap model in real evidence, not from a more expensive
  model guessing. Live web/registry search is gated behind `-Deep`; the default run is
  **offline** (local registry + ensemble synthesis + KB), zero network.
- **d-rg-3 — build/adopt/adapt/inconclusive verdict; advisory, never blocking.** The Gate
  emits a recommendation + candidate options + confidence; it does not stop work. A human or
  the orchestrator reads it and decides. `inconclusive` is the honest verdict (and the
  fallback) when evidence is insufficient.
- **d-rg-4 — two injectable seams → hermetic tests.** Every network touch goes through a
  `-Searcher` scriptblock; every model touch through a `-Dispatcher` scriptblock (mirrors
  Triage's `-Dispatcher` and Projects' `$GhInvoker`). Tests stub both: no network, no real
  model, no real job dir.
- **d-rg-5 — wired to the job `research` phase, runnable standalone.** With an active job the
  verdict writes to `jobs/<id>/phases/research/gate-<ts>.md` (+ `.json`); with no active job
  it goes to stdout (or `-Out`). The Gate requires neither a job nor GitHub.
- **d-rg-6 — box-private targeting.** Worker rosters, endpoints, and any live registry contents
  live only in box-private config, never in the shared seed. The seed `references/fleet.yaml`
  gets the `research` capability on a placeholder provider; placeholders only in any committed
  example.

## 3. Verdict schema (strict JSON the model emits)

```json
{
  "recommendation": "build|adopt|adapt|inconclusive",
  "options": [
    { "name": "<tool/lib/service/internal>",
      "kind": "library|tool|service|internal",
      "fit": "strong|partial|weak",
      "note": "<one line: what it is + why it fits or not>" }
  ],
  "rationale": "<why this recommendation>",
  "next_action": "<one concrete next step>",
  "confidence": 0.0,
  "risk_if_wrong": "low|medium|high"
}
```

| Verdict | Meaning |
|---|---|
| `adopt` | A strong-fit option exists — use it directly. |
| `adapt` | A partial-fit option exists — fork / wrap / configure it. |
| `build` | Nothing fits — build it. |
| `inconclusive` | Insufficient evidence — needs deeper (`-Deep`) or human research. Also the fallback. |

## 4. Architecture

House pattern: a **pure layer** (no network, no model, fully unit-testable) plus a
**seamed dispatch layer** (`-Searcher` for evidence, `-Dispatcher` for synthesis).

### Files

- **`scripts/research-gate-lib.ps1`** — core library.
  - *Pure:*
    - `Get-ToolsRegistrySummary` — parse `tools.yaml` → compact `name — description` list
      (reads a file; no network). The local "do we already have it?" grounding.
    - `Get-EnsembleSynthesis` — find the newest `phases/research/ensemble-*/synthesis.md`
      under a job dir; return its text (or `''` when absent). Reads files only.
    - `Build-GatePrompt` — task text + evidence block (registry + ensemble synthesis + KB
      hits + live-search results) → analyst prompt enforcing the strict-JSON verdict schema.
    - `Get-GateJsonBlock` / `ConvertTo-GateHashtable` — extract + parse the JSON verdict from
      a possibly fenced/prose reply (reuses Triage's first-`{`-to-last-`}` idiom); `$null` on
      no valid object.
    - `Test-GateEscalationNeeded` — `$true` when `confidence < 0.70`, OR `risk_if_wrong=high`,
      OR `recommendation=inconclusive`.
    - `New-GateFallback` — deterministic `inconclusive` verdict for "no worker" / "unparseable"
      (no options, `confidence` low, `next_action` = manual/deeper research).
    - `Format-GateMemo` — pure: verdict hashtable → human-readable markdown memo string.
  - *Seamed:*
    - `Invoke-EvidenceSearch` — gather external evidence through `-Searcher`
      (`{ param($query) ... }`, default = real web + package-registry search; stubbed in tests).
      Returns normalized `@(@{ source; title; snippet; url })`. Only called under `-Deep`;
      offline returns `@()` with **zero** searcher calls.
    - `Invoke-ResearchGate` — orchestrates: resolve input → assemble evidence (registry +
      ensemble synthesis + KB always; live search only if `-Deep`) → `Build-GatePrompt` →
      `Select-Capability -Capability research` (cheap floor, governed) → dispatch cheapest →
      parse → escalate to a champion-ranked second candidate on `Test-GateEscalationNeeded` →
      return the verdict hashtable. `-Dispatcher` + `-Searcher` seams for tests; real path uses
      `Invoke-Fleet`. Mirrors `Invoke-TriageAgent`.
- **`scripts/fleet-research-gate.ps1`** — CLI: input `-Url`/`-File`/`-Text` (reuses Triage's
  one-of-three idiom); flags `-Deep`, `-Json`, `-Out <path>`, `-MaxCostTier`. Resolves the
  active job (via `Read-CurrentJob`/`Read-Manifest` from `job-lib.ps1`); when present, defaults
  the output to `jobs/<id>/phases/research/gate-<ts>.md` (+ `.json`) and prints the path;
  otherwise prints the memo to stdout (`-Json` → JSON; `-Out` → file).
- **`commands/research-gate.md`** — `/baton:research-gate` slash command (shells to
  `$HOME/.claude/scripts/fleet-research-gate.ps1 $ARGUMENTS`).
- **`scripts/test-research-gate.ps1`** — hand-rolled `Check($n,$c)` harness; `-Searcher` and
  `-Dispatcher` stubbed, job dir is a temp dir. Never touches a real network, model, or job.
- **Touched:** `scripts/bootstrap.ps1` (manifest: add `research-gate-lib.ps1`,
  `fleet-research-gate.ps1`), `scripts/test-bootstrap.ps1` (two deploy assertions),
  `.claude-plugin/plugin.json` (`1.2.0-rc.10` → `1.2.0-rc.11`), seed `references/fleet.yaml`
  (add `research` capability to a placeholder provider — box-private note in the file).

## 5. Data flow (`research-gate`)

1. Resolve task text from exactly one of `-Url` / `-File` / `-Text`.
2. Resolve the active job (if any) → its `research` phase dir.
3. Assemble evidence:
   - `Get-ToolsRegistrySummary` (always).
   - `Get-EnsembleSynthesis` from the job's research phase (always if present).
   - `Invoke-KbSearch` top-K (always if the index exists; graceful no-op otherwise).
   - `Invoke-EvidenceSearch` (only with `-Deep`; degrade to offline evidence on searcher error,
     noting it in the memo).
4. `Build-GatePrompt` → `Select-Capability -Capability research` → dispatch the cheapest
   candidate; `New-GateFallback` if no worker or unparseable reply.
5. `Test-GateEscalationNeeded` → on low confidence / high risk / inconclusive, re-dispatch the
   same prompt to a champion-ranked second candidate; keep the better verdict.
6. Output: `Format-GateMemo` → markdown (+ `.json` when in a job, or `-Json`). With an active
   job, write to `phases/research/gate-<ts>.md` / `.json`; else stdout / `-Out`.

## 6. Error handling

- **No research-capable worker** → `New-GateFallback` (`inconclusive`, reason recorded). No throw.
- **Unparseable model reply** → `New-GateFallback`.
- **`-Deep` searcher throws / returns nothing** → degrade to offline evidence; memo notes
  "live search unavailable — verdict from local evidence only."
- **No active job** → emit to stdout / `-Out`; never required.
- **No ensemble synthesis present** → proceed; memo notes "no prior research ensemble."
- **KB index empty / `kb-search` errors** → silent no-op (same posture as `/baton:research`).

## 7. CLI surface

```
/baton:research-gate --text "<task>"   [--deep] [--json] [--out PATH] [--max-cost-tier free|local|paid]
/baton:research-gate --url  <issue-url> [--deep] [--json] [--out PATH]
/baton:research-gate --file <path.md>   [--deep] [--json] [--out PATH]
```

Standalone example:

```
$ baton research-gate --text "convert a folder of PDFs/DOCX to clean markdown"
RESEARCH GATE — recommendation: ADOPT  (confidence 0.78, risk-if-wrong low)
Options:
  • markitdown (library, strong) — Microsoft's doc→markdown; covers PDF/DOCX out of the box.
  • firecrawl parse (tool, partial) — already in your tools registry; handles the same formats.
  • pandoc (tool, partial) — mature, but markdown-from-PDF is weak.
Rationale: two strong/partial options already cover this; building a converter repeats prior art.
Next action: spike markitdown on three sample docs before committing.
```

## 8. Testing (~24 checks)

**Pure layer (no network/model):**
- `Get-ToolsRegistrySummary`: parses a temp `tools.yaml` → `name — desc` lines; empty file → empty.
- `Get-EnsembleSynthesis`: finds the newest `synthesis.md` in a temp job's research phase; absent → `''`.
- `Build-GatePrompt`: includes the task, the evidence block, and the verdict schema.
- `ConvertTo-GateHashtable`: parses fenced JSON, parses prose-wrapped JSON, returns `$null` on garbage.
- `Test-GateEscalationNeeded`: low confidence → true; `risk_if_wrong=high` → true; `inconclusive` → true;
  confident `adopt` low-risk → false.
- `New-GateFallback`: shape is `inconclusive`, no options, low confidence.
- `Format-GateMemo`: renders recommendation, every option, rationale, next_action.

**Seamed (stubbed `-Searcher` / `-Dispatcher`):**
- `Invoke-EvidenceSearch`: stubbed searcher → normalized evidence list; **offline (no `-Deep`)
  makes zero searcher calls and returns `@()`**.
- `Invoke-ResearchGate`: stubbed dispatcher returning an `adopt` JSON → verdict parsed;
  low-confidence first reply → escalation re-dispatch to a champion, better verdict kept;
  dispatcher failure → fallback; `-Deep` invokes the searcher, offline does not.

**CLI:**
- standalone `--text` → memo to stdout; `--json` → JSON; `--out` → file written;
  within a temp active job → writes `phases/research/gate-<ts>.md` + `.json`.
- Zero network and zero real-model calls across the whole suite.

**Bootstrap:** asserts `research-gate-lib.ps1` and `fleet-research-gate.ps1` deploy.

## 9. Risks

- **Hallucinated options.** A cheap model may invent a package. Mitigations: evidence grounding
  (the model is shown real registry/search results), `confidence` + escalation, `fit` honesty,
  advisory-only posture (human verifies before adopting), and `inconclusive` as a safe out.
  Existence-verification is the named Sprint-4.1 follow-on.
- **`gh`/search JSON shape drift** (in `-Deep`). The `-Searcher` seam normalizes results to a
  fixed shape; the canned-evidence test pins it.
- **Token spend under `-Deep`.** One search round + one cheap synthesis (escalate only when
  unsure). Offline default spends nothing on the network. Governed routing (route-around on
  budget exhaustion) caps model spend.
- **Capability seed drift.** Adding a `research` capability must not leak the live roster; only
  a placeholder provider carries it in the seed, with a box-private note.
