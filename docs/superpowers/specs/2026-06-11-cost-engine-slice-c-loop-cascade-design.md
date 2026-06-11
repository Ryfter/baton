# Cost-Optimization Engine — Slice C: cascade in the autonomous loop (design)

**Status:** approved 2026-06-11 (design approved in-session; advisory-mode fork answered "both modes")
**Parent:** `2026-06-10-cost-optimization-engine-design.md` (Slice C scope) · Slice B spec `2026-06-11-cost-engine-slice-b-cascade-design.md`
**Decision lineage:** d026 (cost-optimal orchestrator), d041 (judge-gated cascade), Slice A deferred items (capacity surge unconsumed; concurrent driver never wired).

**Goal:** unattended backlog runs auto-decompose draft→finish across platforms — cheap drafting always allowed, frontier finishing rank-gated at peak — and the concurrent driver gains the Slice A behaviors it never got (rank ordering, paid-peak gate, capacity surge).

## Decisions made

1. **Two cascade modes, keyed on `output_file` presence.** `cascade: true` + `output_file` → **full cascade** (draft→judge→short-circuit-or-finish; winning text written to the file; zero-frontier merges are real). `cascade: true` without `output_file` → **advisory** (draft stage only; best usable draft injected into the agentic implementer's prompt). Kevin chose shipping both modes now.
2. **Cascade items are never gated at the driver.** Drafts are local/free and must not be deferred by a paid-peak gate. The driver passes the item's *effective rank* into `Invoke-CapabilityCascade`; the finisher inside the cascade already runs the Slice B prime-hours gate. Advisory items' *agentic finisher* (paid) is gated at the driver exactly like any non-cascade item.
3. **`finisher-deferred` → item state `deferred`, re-drafts next run.** Drafts are ~free, so losing them on a deferral is acceptable for this slice. Draft caching across runs is named future work, not built.
4. **Parallel draft fan-out = item-level concurrency.** Each cascade item runs in its own child process in the concurrent driver, so multiple items draft in parallel already. Within-cascade parallel drafts would force scriptblock injection across runspace boundaries (breaking the `-Dispatcher`/`-Grader` test seams) — deferred.
5. **One additive cascade seam: `-NoFinisher`.** Stops after drafting+judging. Short-circuit may still fire (`draft-sufficient`); otherwise a new terminal status **`drafts-only`** returns the best *usable* draft (same non-empty-stdout predicate as Slice B salvage). No other cascade change.
6. **`-MaxParallel` defaults to 0 = unbounded (today's behavior).** A `surge` window multiplies only an explicit cap (`ceil(MaxParallel × concurrency_factor)`); multiplying "unbounded" is meaningless. Back-compatible.
7. **Advisory fails open.** Cascade lib missing/throwing, or no usable draft → the item runs its plain agentic prompt unchanged. Full-cascade items have no fallback implementer → `blocked` with the error in reasons.
8. **Serial driver's dead `$cap` assignment is removed.** Serial dispatch has nothing to scale; the capacity profile is consumed where parallelism exists (concurrent driver).

## C.1 Item schema (additive)

```jsonc
{ "id": "write-guide", "model": "codex", "prompt": "...",
  "cascade": true,                  // opt-in; absent → exactly today's behavior
  "output_file": "docs/GUIDE.md",   // present → FULL cascade; absent → ADVISORY
  "capability": "code-gen",         // optional; default "code-gen"
  "rank": 2,
  "allowed_paths": ["docs/*"], "max_files": 20, "test_command": "...", "depends_on": [] }
```

- Full-cascade items may omit `model` (no agentic implementer is used); live JSON reports provider `cascade`. `output_file` is a worktree-relative path; it must fall inside `allowed_paths` for the merge gate to accept it (operator's responsibility, same trust model as today).
- Advisory items require `model` as usual (it names the agentic finisher).
- Existing task JSONs are untouched: no `cascade` field → byte-identical behavior.

## C.2 Cascade lib change — `scripts/routing-cascade.ps1`

`Invoke-CapabilityCascade` gains `[switch]$NoFinisher`:

- Draft + judge stages run exactly as Slice B (serial drafts on the cheapest N draft-eligible candidates; judge grading; heuristic fallback).
- Short-circuit logic unchanged — a qualifying llm-judge score ≥ `GoodEnough` still returns `draft-sufficient` (with `-NoShortCircuit` honored).
- Otherwise, instead of selecting a finisher, return:
  `@{ status='drafts-only'; capability; winner=<best usable draft candidate or $null>; result=<its result or $null>; draft_attempts; finish_attempt=$null; frontier_spent=$false }`
- "Usable" = the Slice B salvage predicate (non-empty trimmed stdout, passing or not).
- `no-candidate` (no draft-eligible candidates) is unchanged and still possible.

No other statuses, parameters, or journal semantics change. (Journal `stage` rows already distinguish draft/finish.)

## C.3 Backlog item resolution — `scripts/fleet-backlog.ps1`

New shared helper (used by both drivers):

```
Get-BacklogCascadeMode -Item → 'full' | 'advisory' | 'none'
```

`'full'` iff `$Item.cascade` is truthy AND `$Item.output_file` non-empty; `'advisory'` iff cascade truthy without output_file; else `'none'`.

New advisory prompt composer (pure, testable):

```
Get-AdvisoryPrompt -Prompt <original> -Draft <text> → <string>
```

Template:

```
<original prompt>

A cheaper model produced this DRAFT. Verify it independently; keep what is
correct, fix what is not, and complete the task:

<draft>
```

### Serial driver (`Invoke-Backlog` / `Invoke-BacklogItem`)

- `Invoke-BacklogItem` gains optional `-CascadeInvoker <scriptblock>` (test seam; default = real `Invoke-CapabilityCascade` with `-Rank <effRank>` and threaded `-PrimeHoursConfig`/`-GateNow`; `Invoke-Backlog` passes effective rank per item).
- **Full mode:** instead of `& $Implementer`, run the cascade with the item's `capability` (default `code-gen`) and prompt. Map status:
  - `draft-sufficient` / `finished` → write `result.stdout` to `output_file` (UTF-8, create parent dirs) inside the worktree, then proceed to the normal merge gate.
  - `finisher-deferred` → item state **`deferred`** (live JSON + runs feed + result object `deferred=$true`), reasons include the cascade reason; not merged, and **it dep-blocks dependents** (they cannot build on unmerged work). NOTE: this also fixes a Slice A gap — the serial driver's existing gate-deferral path does not set the blocked flag, so a deferred prereq's dependents currently run without its work. Slice C makes ALL deferrals (gate and cascade, both drivers) dep-block dependents.
  - `no-candidate` / `no-finisher` / `escalate-to-conductor` / lib error → **`blocked`**, cascade status in reasons.
  - Live JSON extras: `cascade='full'`, `cascade_status`, `frontier_spent`, `winner`.
- **Advisory mode:** run the cascade with `-NoFinisher`. If a usable draft returns (`draft-sufficient` or `drafts-only` with non-null winner), call the implementer with a *clone* of the item whose `prompt` = `Get-AdvisoryPrompt` output. No usable draft / any cascade error → original item unchanged. Then everything proceeds exactly as today (implementer → merge gate). Live JSON extras: `cascade='advisory'`, `draft_winner` (or `$null`).
- The dead `$cap = Get-CapacityProfile` assignment in `Invoke-Backlog` is **removed**.

### Concurrent driver (`Invoke-BacklogConcurrent`) — Slice A parity + cascade

New parameters: `-MaxParallel <int> = 0`, `-FleetPath`, `-PrimeHoursConfig`, `-GateNow` (all injectable; absent → live defaults, same pattern as the serial driver).

Per wave:

1. **Rank order:** compute `Get-EffectiveRanks` once up front. Ready items sort ascending effective rank, then topo index (same tiebreak as serial).
2. **Wave cap:** `$cap = Get-CapacityProfile` (with injected Now/ConfigPath). Effective cap = `0` (unbounded) when `MaxParallel -eq 0`, else `[math]::Ceiling($MaxParallel * ($cap.surge ? $cap.concurrency_factor : 1))`. Take the first ≤cap ready items this wave; the rest stay ready for the next iteration (the existing `while` loop already re-evaluates).
3. **Paid-peak gate (non-cascade-full items only):** resolve the item's provider via `Get-FleetProvider` (fail-open on errors); if `cost_tier -eq 'paid'`, run `Test-PrimeHoursGate -Rank <effRank>`; unattended resolution (`ask` → its default); `defer` → item state **`deferred`** with reason, recorded in `$proc` (dep-blocks dependents), never dispatched. Identical semantics to the serial driver.
4. **Full-cascade items** launch a new `$script:CascadeJobWorker` child instead of `BacklogJobWorker`. The worker receives plain serializable args (cascade lib path, capability, prompt, rank, output_file, worktree path, fleet/tools/prime-hours/journal paths, GateNow ticks or `$null`, result-JSON path): it dot-sources the cascade lib, runs `Invoke-CapabilityCascade`, writes `output_file` on success statuses, and writes a result JSON (`status`, `winner`, `frontier_spent`, `error`) the parent reads after `Wait-Job`. Parent maps statuses exactly as the serial driver (merge gate / deferred / blocked).
   - The cascade lib path is a worker argument so tests can point at the repo copy; production callers default to `~/.claude/scripts/routing-cascade.ps1`.
5. **Advisory items** also run through `CascadeJobWorker` first? No — to keep one child per item, the advisory draft runs **inside a pre-step of the same child**: a new `$script:AdvisoryJobWorker` dot-sources the cascade lib, runs `-NoFinisher`, composes the prompt (same template; duplicated inline in the worker because child jobs have no dot-sourced helpers — a test asserts the two templates stay in sync by comparing against `Get-AdvisoryPrompt`), writes it to the prompt file, then pipes it to the agentic `exe`/`args` exactly as `BacklogJobWorker` does. Cascade failure inside the worker → plain prompt (fail-open), `draft_winner=$null` in its result JSON.
6. Child processes are isolated, so the `$script:__lastGateDecision` module-scoped carry flagged in Slice A never races.

### `scripts/run-backlog.ps1`

- New `-MaxParallel` passthrough param (default 0).
- Summary print gains a `deferred` tag and, for cascade items, the winner + `frontier_spent` line.

## C.4 Surfaces

No new slash command. `run-backlog.ps1` header documents the new item fields; `docs/next-session.md` gets the closeout entry. (The `/baton:route` cascade surface shipped in Slice B; an MCP `route-cascade` op stays a ride-along for any future MCP touch.)

## C.5 Errors

- Cascade lib unreadable / `Invoke-CapabilityCascade` throws: advisory → plain prompt (fail-open, warn in live JSON); full → `blocked` with `cascade-error: <message>`.
- `output_file` escaping the worktree (`..` / rooted path) → `blocked` with `cascade-error: output_file outside worktree` (cheap guard, same trust posture as `Publish-ItemRun`).
- Missing/garbage prime-hours or fleet config: fail-open everywhere (gate allows; no provider → no gating) — inherited behavior.
- A deferred item is always reported (live JSON, runs feed, result object) and dep-blocks its dependents; it is never silently dropped.
- Worker child crash (`result JSON missing` after `Wait-Job`): full → `blocked` `cascade-error: worker produced no result`; advisory falls back to... the child *is* the implementer run, so a crashed child = implemented-with-error exactly as today's `BacklogJobWorker` exit≠0 path.

## C.6 Testing

Hermetic throughout: temp GUID dirs, temp git repos (existing suite fixtures), temp `fleet.yaml`/`tools.yaml` with echo `command_template` providers (real dispatch path, zero LLM), explicit `role:` annotations to force draft/finisher partitions, injected `-GateNow`/`-PrimeHoursConfig`, injected `-CascadeInvoker` where in-process, temp `BATON_HOME`. Never touches real state.

**Serial (`test-fleet-backlog.ps1`):**
1. Full-cascade short-circuit (injected invoker returns `draft-sufficient`) → `output_file` exists in worktree with draft text, item merges, result carries `frontier_spent=$false`.
2. Full-cascade `finisher-deferred` → state `deferred`, `deferred=$true`, not merged, dependents dep-blocked.
3. Full-cascade `escalate-to-conductor` → `blocked`, reason carries the status.
4. Advisory with usable draft → fake implementer observes composed prompt containing draft text + original prompt.
5. Advisory with no usable draft (`drafts-only`, winner `$null`) → implementer observes the original prompt verbatim.
6. Advisory cascade throws → original prompt (fail-open).
7. `output_file` traversal guard → `blocked`.
8. No `cascade` field → existing suite green unchanged (back-compat).

**Concurrent (`test-fleet-backlog-concurrent.ps1`):**
9. Rank ordering: `MaxParallel=1`, three independent items ranks 3/1/2 → processed ascending effective rank (assert via merge order in results).
10. Paid-peak gate: temp peak config + `GateNow` inside it, paid provider, rank 3 → `deferred`, never launched.
11. Effective-rank inheritance: rank-3 prereq of a rank-1 dependent gates as rank 1.
12. Surge cap math: pure helper unit-test (`MaxParallel=2`, factor 2, surge → 4; no surge → 2; `MaxParallel=0` → unbounded regardless).
13. Full-cascade e2e through `CascadeJobWorker` with echo providers (explicit `role: finisher` on a free echo entry) → `output_file` written + merged.
14. Advisory template sync: worker's inline template equals `Get-AdvisoryPrompt` output.
15. Back-compat: existing concurrent tests green with no new params.

**Bootstrap:** no manifest change (`fleet-backlog.ps1`, `run-backlog.ps1`, `routing-cascade.ps1` already deploy); existing bootstrap suite must stay green.

## Out of scope (named)

- Within-cascade parallel drafts (runspace-crossing test seams) — future refinement.
- Draft caching across runs (deferred items re-draft; drafts are ~free).
- MCP `route-cascade` bridge op — ride-along for a future MCP touch.
- The autonomous folder+repo run-loop epic — Slice C is its on-ramp, not it.
- Stage-aware learning (journal `stage` data feeding `Get-CapabilityQuality`).

## Files

- **Modify:** `scripts/routing-cascade.ps1` (`-NoFinisher` + `drafts-only`), `scripts/test-routing-cascade.ps1`, `scripts/fleet-backlog.ps1` (helpers + both drivers), `scripts/test-fleet-backlog.ps1`, `scripts/test-fleet-backlog-concurrent.ps1`, `scripts/run-backlog.ps1`, `docs/next-session.md` (closeout).
- **Create:** this spec + the implementation plan.
