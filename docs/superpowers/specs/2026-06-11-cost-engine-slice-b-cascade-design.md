# Cost-Optimization Engine — Slice B: model-role registry + cascade primitive (design)

**Status:** approved 2026-06-11
**Parent spec:** `docs/superpowers/specs/2026-06-10-cost-optimization-engine-design.md` (Levers 3 + 4)
**Decision lineage:** d026 (cost-optimal orchestrator), Slice A (rank gate + capacity profile, SHIPPED), routing S1–S4 (SHIPPED).

## Goal

Spend top-tier compute only on the final delta. Cheap models draft; a frontier model
finishes — and when a draft is already good enough, nothing frontier runs at all.

## Decisions made

1. **Short-circuit ON by default** (Kevin, 2026-06-11): a draft scoring ≥ `GoodEnough`
   (default **0.9**) ships as-is with zero frontier spend.
2. **Short-circuit requires a scored verdict.** The heuristic grader is binary
   (pass = 1.0), which would trip a 0.9 threshold on every pass. Therefore the
   short-circuit fires only when the verdict's `grader = 'llm-judge'`. The cascade
   defaults to judge grading; if the judge is unavailable (no local model, judge error)
   grading falls back to heuristic **and the short-circuit disables** — the cascade
   always finishes. Quality floor preserved; fail-open preserved.
3. **Selector stays role-blind.** `Select-Capability` ranking is untouched
   (optimizer-first invariant). It only *passes through* `role`/`platform` fields so
   the cascade can filter. Only the cascade consumes roles.
4. **New lib file** `scripts/routing-cascade.ps1`, following the slice-per-file
   convention (`routing-lib` → `routing-dispatch` → `routing-learn` → `routing-calibrate`).
5. **`platform` field added now** (Lever 4 concept-anchoring): journaled metadata,
   no behavior until the cost/speed advisor.
6. **MCP exposure out of scope** — a `route-cascade` bridge op + tool is a follow-up
   ride-along, not part of this slice.
7. **Serial drafting.** Parallel fan-out belongs to Slice C (capacity surge / concurrent
   driver), not the primitive.

## B.1 Registry metadata (`fleet.yaml` / `tools.yaml`)

Two new **optional** per-entry fields, parsed by the existing generic `key: value`
readers (no parser change needed):

```yaml
  - name: ollama-local
    role: draft            # draft | bulk | finisher
    platform: local        # claude | codex | gemini | github | local
```

**Role semantics:**

| Role | Cascade stage | Typical entries |
|---|---|---|
| `draft` | drafting fan-out | local Ollama / LM Studio models |
| `bulk` | drafting fan-out (same eligibility as draft) | Haiku/Sonnet-class cheap-paid, gh-copilot |
| `finisher` | final pass | claude-cli, codex (Opus/Fable/frontier GPT) |

**Inference when `role` is absent** (fail-open, zero-config keeps working):
`cost_tier: local|free` → draft-eligible; `cost_tier: paid` → finisher-eligible.
**Explicit beats inferred** — that is how a cheap-paid (Haiku/Sonnet) entry becomes a
drafter despite `cost_tier: paid`, and how a strong local model could be promoted to
finisher. `bulk` exists as a distinct label for the advisor/Slice C; the cascade treats
it as draft-eligible.

**Seed YAMLs** (`references/fleet.yaml`, `references/tools.yaml`) get explicit
`role:` + `platform:` annotations on every entry. tools.yaml entries are all
`role: draft`-class specialized tools today; they keep working unannotated via inference.

**Selector passthrough:** `Select-Capability` candidate objects gain `role` and
`platform` properties (raw registry value or `$null`). Ranking, filtering, and the
`score` expression are unchanged.

## B.2 Journal extension

`Write-RoutingJournalLine` gains an optional `-Stage <string>` (`draft` | `finish`);
when provided, the JSONL row carries `stage`. Rows without the field are unchanged —
all existing readers (`Read-JsonlRows`, learning loop, dashboard) are tolerant.
Cascade rows feed the same per-(capability,candidate) learning loop as every other
dispatch; stage-aware learning is a later refinement if the data warrants it.

## B.3 The cascade primitive — `scripts/routing-cascade.ps1`

```
Invoke-CapabilityCascade
  -Capability <string> -Prompt <string>
  [-DraftCount 3]                  # cheapest N draft-eligible candidates
  [-GoodEnough 0.9]                # short-circuit threshold (judge-scored)
  [-NoShortCircuit]                # force the finisher even on great drafts
  [-Grader <scriptblock>]          # test seam; wins over -Judge
  [-Judge] [-JudgeModel <name>]    # judge grading — ON by default (see below)
  [-Rank <int>]                    # prime-hours gate for the finisher (Slice A)
  [-PrimeHoursConfig <path>] [-GateNow <datetime>]
  [-MaxCostTier <tier>] [-RequireLocal]
  [-TimeoutS 120]
  [-Dispatcher <scriptblock>] [-JudgeDispatcher <scriptblock>]   # test injection
  [-ToolsPath] [-FleetPath] [-JournalPath]
  → [pscustomobject]@{ status; capability; winner; result;
                        draft_attempts; finish_attempt; frontier_spent }
```

**Grader resolution:** `-Grader` wins (tests); else judge grading is the default
(`Get-LlmJudgeGrader`, threshold 0.6 pass-gate as in S3). `-Judge:$false` is not
offered — heuristic-only cascading is the *fallback*, not a mode (decision 2).

**Flow:**

1. `Select-Capability` (with `-MaxCostTier`/`-RequireLocal` passed through).
   No candidates → `no-candidate`.
2. Partition by effective role (explicit `role`, else tier inference).
   Take the first `DraftCount` draft-eligible candidates in the selector's
   cost-ascending order.
3. Dispatch each draft **serially** via `Invoke-RoutedCandidate` (journal `stage=draft`).
   Drafts are local/free (or cheap-paid by explicit role) — the prime-hours gate is
   not consulted for them unless a draft is `paid`-tier, in which case
   `Invoke-RoutedCandidate`'s existing `-Rank` path applies as-is.
   Track the best attempt by `score`.
4. **Short-circuit:** best draft `passed` ∧ `score ≥ GoodEnough` ∧ verdict grader is
   `llm-judge` ∧ not `-NoShortCircuit` → return `status='draft-sufficient'`,
   `winner = <draft>`, `frontier_spent = $false`. Zero frontier cost.
5. Otherwise pick the **first finisher-eligible candidate** in selector order
   (cheapest capable finisher). None (e.g. `-RequireLocal`) → `status='no-finisher'`,
   best passing draft (if any) returned as the result.
6. Build the finisher prompt:
   - best draft exists (any passing draft, else highest-scoring non-passing one with
     non-empty stdout): original prompt + the draft + take-and-extend instruction
     (template below);
   - no usable draft at all → the original prompt alone (degenerates to a plain
     routed dispatch).
7. Dispatch the finisher via `Invoke-RoutedCandidate` with `-Rank` (Slice A gate —
   this is the paid/peak step). Gate defers it → `status='finisher-deferred'`,
   best draft returned as **provisional** result (work is never lost), journal row
   records the deferral (existing gate path).
8. Grade the finisher output (journal `stage=finish`). Passed → `status='finished'`,
   `winner = <finisher>`, `frontier_spent = $true`. Failed → `status='escalate-to-conductor'`
   with the best draft attached in `result` (the conductor decides; PowerShell cannot
   invoke Claude).

**Finisher prompt template** (single source of truth in the lib, test-asserted):

```
You are finishing another model's draft. TASK:
<original prompt>

DRAFT (may be incomplete or flawed — keep what is good, fix what is not,
extend to fully satisfy the TASK; output ONLY the finished result):
<best draft stdout>
```

**Statuses:** `draft-sufficient | finished | finisher-deferred | no-finisher |
no-candidate | escalate-to-conductor`. `frontier_spent` is the headline cost metric:
`$true` only when a paid finisher actually dispatched.

## B.4 Command surface — `/baton:route --cascade`

`commands/route.md` gains a `--cascade` mode (sibling of `--run/--calibrate/--rank`):

```
/baton:route <capability> --cascade "<prompt>" [--drafts N] [--good-enough 0.9] [--rank R]
```

Display: per-draft rows (candidate, tier, score, duration), the short-circuit or
finisher decision with its reason in plain language, and a closing cost line —
e.g. `frontier spend: none (draft-sufficient at 0.94)` or
`frontier spend: 1 finisher pass (codex)`. Interactive `ask` from the gate surfaces
as a prompt, matching `--run` semantics.

## B.5 Errors & edge cases

- **All drafts fail:** finisher runs with the original prompt alone (step 6) — the
  cascade degenerates gracefully to escalate-style dispatch; statuses still apply.
- **Judge unavailable:** heuristic fallback per S3 grader; short-circuit disabled
  (decision 2); cascade proceeds to the finisher.
- **No draft-eligible candidates** (e.g. everything is paid/finisher): skip drafting,
  go straight to the finisher with the original prompt; `draft_attempts = @()`.
- **Registry without role fields:** pure inference — yesterday's YAMLs work untouched.
- **Gate fail-open:** inherited from Slice A — bad prime-hours config never blocks.
- **Journal/ratings write faults:** warn-and-continue (existing behavior).

## B.6 Testing — `scripts/test-routing-cascade.ps1`

Injected `-Dispatcher`/`-JudgeDispatcher`/`-Grader` + temp `BATON_HOME`; zero live
model calls, zero clock dependence (`-GateNow`). Cases:

1. Role partition: explicit `role` beats tier inference; `bulk` is draft-eligible;
   unannotated registry infers correctly.
2. Selector passthrough: candidates expose `role`/`platform`; ranking unchanged
   vs an unannotated registry (golden ordering).
3. Short-circuit fires: judge-graded draft ≥ 0.9 → `draft-sufficient`,
   `frontier_spent=$false`, finisher dispatcher never invoked (call-count probe).
4. Short-circuit suppressed on heuristic verdict (judge unavailable) → finisher runs.
5. `-NoShortCircuit` forces the finisher past a 0.95 draft.
6. Below-threshold drafts → finisher prompt contains both the original prompt and the
   best draft (template asserted); `status='finished'`, `frontier_spent=$true`.
7. All drafts fail → finisher gets the original prompt alone.
8. Gate defers the finisher (peak window, rank 3, injected `-GateNow`) →
   `finisher-deferred` + provisional best-draft result.
9. `-RequireLocal` → `no-finisher` + best draft.
10. Finisher fails grading → `escalate-to-conductor` with draft attached.
11. Journal rows carry `stage=draft`/`stage=finish`; rows without stage unaffected
    (reader tolerance).
12. `DraftCount` caps the fan-out; order follows the selector ranking.

Plus: `test-bootstrap.ps1` asserts `routing-cascade.ps1` deploys;
`test-baton-home.ps1`'s stale-literal guard covers the new file automatically.

## Files

- **Create:** `scripts/routing-cascade.ps1`, `scripts/test-routing-cascade.ps1`, this spec.
- **Modify:** `scripts/routing-lib.ps1` (role/platform passthrough),
  `scripts/routing-dispatch.ps1` (`-Stage` on `Write-RoutingJournalLine`),
  `references/fleet.yaml` + `references/tools.yaml` (role/platform annotations),
  `commands/route.md` (`--cascade`), `scripts/bootstrap.ps1` + `scripts/test-bootstrap.ps1`
  (deploy the new lib), `docs/next-session.md` + memory (closeout).

## Out of scope (tracked)

- **MCP `route-cascade` op/tool** — follow-up ride-along after the slice ships.
- **Parallel draft fan-out + backlog-driver wiring** — Slice C.
- **Stage-aware learning** (separate draft vs finish quality) — only if journal data
  shows the need.
- **Advisor consumption of `platform`** — the cost/speed advisor slice.
