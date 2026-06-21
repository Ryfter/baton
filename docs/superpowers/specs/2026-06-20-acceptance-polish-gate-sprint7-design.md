# Sprint 7 — Acceptance/Polish Gate (design)

**Status:** approved 2026-06-20 · **Sprint:** 7 of 7 (final MVP sprint) · **Line:** v1.3.0

## 1. Problem & identity

Baton's economic thesis is "spend intelligence like money": cheap work that is
*good enough* should ship as-is (**acceptable**); only work that needs it should
pay for a premium pass (**polished**). Sprint 2's cascade
(`routing-cascade.ps1`) already implements the *economic* half of this — cheap
drafts, an llm-judge short-circuit that ships at $0, a premium finisher
take-and-extend. What is missing is the *quality acceptance decision*: a formal,
auditable gate that looks at a **finished work artifact** and decides whether it
is acceptable, needs polish, or must be rejected.

The Acceptance/Polish Gate is the **after-work mirror of the Research Gate**.
Research Gate decides **build/adopt/adapt** *before* work; the Acceptance Gate
decides **accept/polish/reject** *after* work. Both are advisory, seamed,
hermetic, box-private, and follow the established Baton sprint pattern (pure lib +
seamed I/O + `fleet-*.ps1` CLI + `/baton:*` command + hermetic test suite +
bootstrap manifest + plugin bump), riding box-private `$BATON_HOME`.

It is distinct from the cascade's scalar llm-judge: the gate runs a **competitive
review** (≥2 reviewers independently find issues; findings are compared and
reconciled) and produces a **severity-weighted, deduped finding set** plus a
ready-to-use **polish brief** — not just a pass/fail score.

## 2. Decisions

- **d-ag-1 — Standalone advisory gate, not an auto-polish loop.** On a `polish`
  verdict the gate emits the verdict + merged findings + a ready-to-use polish
  brief; it does **not** itself dispatch the premium finisher or re-gate. The
  operator or the Conductor decides whether to run the polish pass. Mirrors the
  Research Gate and Sprint 6's deferral of active drivers; cleanest seam, smallest
  blast radius. *(Auto-polish loop = tracked follow-up.)*
- **d-ag-2 — Competitive review = independent + deterministic reconcile.** Each
  reviewer reviews the artifact independently; the pure layer normalizes, dedupes,
  and tags findings `agreed` (raised by ≥2) vs `solo`. No adversarial cross-exam
  round and **no third LLM "chair" call** — reconciliation and verdict are pure
  and deterministic. *(Cross-exam = tracked follow-up.)*
- **d-ag-3 — Reviewers emit strict JSON findings.** Each reviewer is prompted to
  output ONLY a JSON array `[{"severity","area","summary"}]` (empty array = clean),
  mirroring triage's structured output. The pure layer parses it; the seam never
  parses prose. Artifact is delivered to reviewers via **stdin** (quote-safe).
- **d-ag-4 — Fail-open parsing.** A reviewer returning unparseable output degrades
  to one "unparsed" review (noted in the result), never crashes, and never
  silently inflates or deflates the verdict. Mirrors `Get-RateLimitState`.
- **d-ag-5 — Verdict rule (parameterized, severity-driven).** Default: any
  `critical` finding → `reject`; else any `important` → `polish`; else
  (`minor`/none) → `accept`. Thresholds are function parameters with these
  defaults so tests drive them and a box can tune them.

## 3. Components

### 3.1 `scripts/gate-lib.ps1`

**Pure layer:**

- `Get-FindingSeverityRank([string]$Severity) -> int` — `critical`=3,
  `important`=2, `minor`=1, unknown/absent=0. Case-insensitive; clamps.
- `Get-ReviewFindings([string]$Output) -> [hashtable]` — parse one reviewer's
  output into `@{ parsed=[bool]; findings=@(@{severity;area;summary}); raw=[string] }`.
  Tolerant: accepts a bare JSON array or a JSON array embedded in surrounding text
  (extract first `[ ... ]`); each finding's severity normalized to the taxonomy
  (unknown severities kept as `minor` floor with the raw value preserved in
  `area`/`summary` only — never dropped). Unparseable → `parsed=$false`,
  `findings=@()`. Empty array → `parsed=$true`, `findings=@()`. **Empty-array
  guard:** always returns a real array, never a unary-comma wrapper.
- `Merge-ReviewFindings([array]$Reviews) -> [hashtable]` — input is the per-reviewer
  parse results (each `@{ reviewer; parsed; findings }`). Returns
  `@{ merged=@(@{severity;area;summary;raised_by=@();agreed=[bool]}); unparsed=@(reviewer names) }`.
  Dedupe key = normalized (lowercased, whitespace-collapsed) `area`+`summary`;
  when two reviewers raise the same finding, keep the **higher** severity and set
  `agreed=$true` with both names in `raised_by`. Empty/all-unparsed → `merged=@()`.
- `Get-AcceptanceVerdict([array]$MergedFindings, [string]$RejectAt='critical', [string]$PolishAt='important') -> [hashtable]`
  — returns `@{ verdict; reason; counts=@{critical;important;minor} }`. Rule per
  d-ag-5, expressed via `Get-FindingSeverityRank` thresholds so the cutoffs are
  tunable. `reason` is a one-line human string (e.g. "1 critical finding").
- `Format-PolishBrief([hashtable]$Verdict, [array]$MergedFindings) -> [string]` —
  the ready-to-hand brief for a premium polish pass: lists the **must-fix**
  findings (critical+important), agreed-first, each as `[severity][area] summary`.
  Returns a short "no polish needed" line when verdict is `accept`.
- `Format-GateReport([hashtable]$Result) -> [string]` — human-readable: verdict +
  reason + counts, then findings grouped agreed/solo, then the unparsed-reviewer
  note if any.

**Seamed layer:**

- `Invoke-AcceptanceGate` — params: `-Artifact [string]` (the work product text),
  `-Task [string]` (one line: what it was supposed to do), `-Reviewers [string[]]`
  (provider names; default = enabled providers claiming the `review` capability),
  `-Dispatcher [scriptblock]` (default dispatches each reviewer through the routed
  fleet), `-FleetPath`, plus the verdict-threshold passthroughs. Builds one
  structured-review prompt per reviewer (artifact via stdin), dispatches each
  **independently**, parses (`Get-ReviewFindings`), merges (`Merge-ReviewFindings`),
  verdicts (`Get-AcceptanceVerdict`), briefs (`Format-PolishBrief`). Returns
  `[ordered]@{ verdict; reason; counts; findings; polish_brief; reviews=@(per-reviewer @{reviewer;parsed;count}) }`.
  Box-private; tests inject `-Dispatcher` returning canned JSON, never touching
  the network. Zero reviewers → throws a clean error.

### 3.2 `scripts/fleet-gate.ps1` (CLI)

`run` subcommand: resolve the artifact from `--file <path>` | `--diff <range>`
(runs `git diff <range>`) | stdin/`--artifact`; require `--task`; optional
`--reviewers a,b`, `--json`. `$BATON_HOME`-derived `$FleetPath`. Calls
`Invoke-AcceptanceGate`, prints `Format-GateReport` (or the ordered object as JSON
under `--json`).

### 3.3 `commands/gate.md`

`/baton:gate run|<...>` → `pwsh scripts/fleet-gate.ps1 $ARGUMENTS`.

### 3.4 `references/fleet.yaml`

Add `review` to the capability taxonomy comment block. Grant `review` to a couple
of capable existing seed entries (e.g. `claude-sonnet`) as the example reviewer
pool. The real Codex+Opus reviewer pair and any budgets are **box-private** — set
only in live `~/.baton/fleet.yaml`, never in the seed.

## 4. Error handling

- Zero reviewers configured/selected → `Invoke-AcceptanceGate` throws a clear
  message; CLI surfaces it and exits non-zero.
- A reviewer dispatch fails or returns garbage → counted as `unparsed`, excluded
  from the merged set, named in the result; verdict computed on survivors.
- All reviewers unparsed → `merged=@()`, verdict `accept` with a reason flagging
  that no usable review was obtained (advisory, fail-open — never falsely blocks).
- No findings anywhere → `accept`.
- Missing `--file`/`--diff`/stdin or missing `--task` → CLI usage error.

## 5. Hermetic testing (`scripts/test-gate-lib.ps1`, ~25–30 checks)

Check harness; temp dirs; try/finally cleanup; zero network. Coverage:
- `Get-FindingSeverityRank`: each tier + unknown + case-insensitivity.
- `Get-ReviewFindings`: bare JSON array; array embedded in prose; empty array;
  garbage→`parsed=$false`; partial/missing fields normalized; unknown severity
  preserved-not-dropped; empty-array guard returns real array.
- `Merge-ReviewFindings`: agreed dedupe (both raise same → one merged, `agreed`,
  higher severity kept); solo findings tagged; unparsed reviewers listed;
  all-unparsed → empty merged.
- `Get-AcceptanceVerdict`: critical→reject, important→polish, minor/none→accept,
  tunable thresholds, correct counts.
- `Format-PolishBrief` / `Format-GateReport`: must-fix content present, accept
  short-circuit line, agreed/solo grouping, unparsed note.
- Seamed `Invoke-AcceptanceGate` with `-Dispatcher` stubs: two reviewers agree +
  one solo + one garbage→degraded; zero-reviewers throw; ordered-result shape.
- CLI child-process (`fleet-gate.ps1`) with temp `$env:BATON_HOME` + temp
  fleet.yaml fixture + `--file` artifact fixture; `--json` shape; `run` verdict.

Bootstrap: `gate-lib.ps1` + `fleet-gate.ps1` added to the manifest; 2 new
`test-bootstrap.ps1` asserts.

## 6. Box-private

Reviewer roster, the real Codex+Opus pair, and any per-window budgets live ONLY
in live `~/.baton/fleet.yaml`. The seed carries the `review` capability + a
placeholder example grant. No real endpoints, rosters, or budgets in the repo.

## 7. Risks & mitigations

- **Reviewer JSON drift** (a model wraps the array in markdown fences / prose):
  `Get-ReviewFindings` extracts the first `[ ... ]` block and fail-opens on the
  rest. Regression-tested with an embedded-in-prose case.
- **Dedupe false-merge / false-split** (same issue worded differently):
  normalized key is deliberately conservative (area+summary, lowercased,
  whitespace-collapsed); divergent wordings stay `solo` rather than being
  wrongly merged — solo findings still count toward the verdict, so the gate
  never *under*-reports by failing to merge.
- **Over-rejection** (a single hallucinated `critical` blocks acceptable work):
  verdict thresholds are parameters; `agreed` vs `solo` is surfaced so the
  operator can see a lone unconfirmed critical. (Auto-discount of solo findings =
  tracked follow-up, not MVP.)

## 8. Scope (YAGNI) & tracked follow-ups

**In scope:** the standalone `/baton:gate` + a `Invoke-AcceptanceGate` signature
the Conductor can call later. **Deferred (tracked):** auto-polish loop (d-ag-1);
adversarial cross-exam round + LLM chair (d-ag-2); Conductor/job-phase wiring of
the gate into a merge/acceptance phase; solo-finding auto-discount.

## 9. Deliverable

Plugin `1.3.0-rc.1` → `1.3.0-rc.2` (continues the open, untagged v1.3.0 line).
Completes 7 of 7 MVP sprints.
