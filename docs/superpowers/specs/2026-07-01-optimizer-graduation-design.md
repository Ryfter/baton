# Optimizer Graduation — pilot → real GEPA (design)

**Date:** 2026-07-01 · **Status:** approved in brainstorm (Kevin) · **Builds on:** d069/d070 pilot (`/baton:optimize-prompt`), d060 effective_cost, d066 CostResolver
**Research base:** `~/.claude/knowledge/projects/baton/notes/agent-routing-and-tools.md` §6–7 (GEPA arXiv 2507.19457; DeepEval blueprint; Decagon production tuning)

## Goal

Graduate the shipped single-shot reflect-and-propose pilot into a real GEPA
(Genetic-Pareto) loop: a persistent candidate pool with lineage, a two-model
reflection/mutation split, a minibatch evaluation, and a dual acceptance gate
that pre-filters what is worth proposing. Human `--apply` stays the deployment
gate (d070 unchanged).

## North-star metric (Kevin, 2026-07-01)

The target is **total realized cost to an accepted outcome**, not per-token
price. A prompt (or model) that is cheaper per call but triggers more rework —
polish loops, re-runs, extra reasoning tokens — can be a net loss: 10 runs of
a cheap model at $1.20 each lose to 1 run of a frontier model at $10. The
per-variant bookkeeping must be able to prove this direction with numbers.

Concretely:
- **Slice A (offline)** cannot measure realized cost, so its quality axis —
  the judge score — is explicitly a *predictor of fewer rework loops*, and its
  cost axis is prompt token length (paid on every single run).
- **Slice B (live, deferred)** measures the real thing: per-variant
  CostResolver-metered realized cost *including* rework, accumulated in the
  same pool records, so no migration is needed when it lands.

## Scope

**Slice A (this build):** pool state + select/reflect/mutate/evaluate/gate
loop, offline only, driven by `/baton:optimize-prompt`.

**Slice B (named, deferred — own spec/plan later, and may be re-prioritized
against other tracks):** live shadow A/B — a gate-surviving candidate becomes
*challenger*, live `/baton:go` runs alternate champion/challenger, verdicts +
realized cost accrue per variant, report recommends promote/retire in dollars.
Slice A's only obligation to it is the pool schema below.

**Non-goals:** optimizing any prompt other than the Conductor planner prompt;
autonomous deployment (d070 stands); DSPy or any Python dependency (d069
stands); wiring into `Complete-Run` (that is Slice B).

## State: the candidate pool (box-private)

`BATON_HOME/prompts/pool/` — `pool.json` manifest + one `pNNN.txt` per
candidate. Never enters the knowledge repo or any shared seed.

```json
{
  "schema": 1,
  "champion": "p001",
  "candidates": [
    {
      "id": "p001",
      "file": "p001.txt",
      "parent": null,
      "origin": "seed",
      "created": "2026-07-01T22:00:00Z",
      "status": "champion",
      "offline": {
        "times_selected": 0,
        "prompt_tokens": 412,
        "minibatch": { "wins": 0, "losses": 0, "ties": 0, "win_rate_vs_champion": 0.5, "examples": [] }
      },
      "live": {
        "runs": 0, "accept": 0, "polish": 0, "reject": 0,
        "realized_cost_usd": 0.0, "rework_cost_usd": 0.0
      }
    }
  ]
}
```

- `status`: `champion` | `candidate` | `retired`. Exactly one champion.
- `origin`: `seed` | `mutation`.
- `prompt_tokens`: estimated as `ceil(chars / 4)` — no tokenizer in
  PowerShell; the estimate only needs to be monotone and consistent.
- `live.*` is written only by Slice B; Slice A creates the fields at zero.
- **Pool bootstrap:** if `pool.json` is absent, seed it from the live
  `BATON_HOME/prompts/conductor-planner.txt` as `p001`/champion. The
  conductor's prompt-resolution chain is untouched — the live file remains
  the single source the planner reads; the pool is bookkeeping around it.

## Slice A loop (one generation)

`Invoke-PromptEvolution` runs `--generations N` (default 1) of:

1. **Select** — `Select-ParentCandidate`: frequency-weighted random pick from
   the Pareto front (DeepEval); degenerates to the champion while the pool is
   young. Weight = 1 / (1 + times_selected) to spread exploration.
2. **Reflect** — cheap-side model (existing `Select-Capability -Capability
   reasoning`, tier = `--reflect-tier`, default one below mutation) diagnoses
   the parent's failures from the gated-run history (findings, polish briefs —
   the ASI channel) plus one-line fates of prior candidates ("p003 rejected:
   dropped {{evi}}").
3. **Mutate** — stronger model (tier = `--max-tier`, default `paid`) produces
   the child prompt inside `<new_prompt>` tags. Placeholder validation
   (`{{schema}}`/`{{evi}}`/`{{Goal}}`) and the **length cap** (default: child
   tokens ≤ 2× seed-prompt tokens, configurable) reject the mutation outright
   before any evaluation is spent — Decagon's regularization.
4. **Evaluate (minibatch)** — `Invoke-MinibatchEval`: for each historical
   polish/reject run (up to `--max-runs`, default 5, cap 20), generate a plan
   with the child prompt and with the reference prompt (plan-only calls — no
   execution), then a judge model scores which plan better addresses that
   run's recorded gate findings, answering `<verdict>A|B|tie</verdict>`.
   Prompt order is swapped per example to cancel position bias.
   - Always evaluated **vs the champion** → `win_rate_vs_champion` (the
     comparable Pareto quality axis; champion is 0.5 by definition).
   - If the parent is not the champion, a second head-to-head **vs the
     parent** feeds the gate arm.
   - `win_rate = wins / (wins + losses)`, ties excluded; all-ties = no
     evidence = gate fails.
5. **Dual gate** — `Test-DualGate`: the child survives only if it
   (a) beats its parent (`win_rate_vs_parent > 0.5`), AND
   (b) is Pareto-non-dominated in the pool on
   (`win_rate_vs_champion` ↑, `prompt_tokens` ↓).
   Survivors are recorded in the pool as `candidate` and written as the
   proposal file (`conductor-planner.candidate.txt`, unchanged surface).
   Non-survivors are recorded as `retired` with the reason — they are
   reflection fuel for later generations, not deleted.
6. **Apply (human, unchanged)** — `--apply` promotes the surviving candidate:
   champion text written to the live `conductor-planner.txt` (with the
   existing timestamped `.bak`), pool statuses swapped
   (old champion → `retired`, reason `superseded`), new champion recorded.

Every model call goes through the existing fleet routing; every failure
fail-opens to "no proposal this generation" with an honest reason — the loop
never leaves the pool half-written (manifest is saved once, at the end of the
generation).

## Files

- **Create `scripts/prompt-pool-lib.ps1`** — pure/seamed pool logic:
  `Get-PromptPool`, `Save-PromptPool`, `Initialize-PromptPool` (seed
  bootstrap), `Get-ParetoFront`, `Select-ParentCandidate`, `Test-DualGate`,
  `Get-PromptTokenEstimate`.
- **Modify `scripts/optimize-prompt-lib.ps1`** — add `Invoke-MinibatchEval`
  (seams: `-PlanDispatcher`, `-JudgeDispatcher`) and `Invoke-PromptEvolution`
  (orchestration; keeps `-Dispatcher`-style seams throughout). The v1
  single-shot `Invoke-PromptOptimizer` remains as the degenerate
  `--generations 0` compatibility path? **No — YAGNI:** it is replaced;
  `Invoke-PromptEvolution -Generations 1` with an empty pool reproduces its
  behavior (reflect on history, propose one candidate, gated apply).
- **Modify `scripts/fleet-optimize-prompt.ps1`** — flags: existing
  `-MaxRuns/-MaxCostTier/-Json/-Apply` plus `-Generations <n>`,
  `-ReflectTier <t>`, `-Pool` (print the pool report: per-variant lineage,
  scores, status, and — once Slice B writes them — live cost-to-acceptance).
- **Modify `commands/optimize-prompt.md`**, **`docs/COMMANDS.md`** — document
  the evolved flow.
- **Modify `scripts/bootstrap.ps1` / `test-bootstrap.ps1`** — deploy
  `prompt-pool-lib.ps1`; the pool directory is runtime state, created on
  first use, never seeded.
- **Create `scripts/test-prompt-pool-lib.ps1`**, extend
  `scripts/test-optimize-prompt-lib.ps1` — hermetic house Assert style, temp
  BATON_HOME, all model calls behind dispatcher seams.

## Error handling

House rules throughout: `[Console]::Error.WriteLine` (never `Write-Error`
under Stop), CLI exits 2 on hard failure, every fallback labels itself
honestly in the returned `reason`. Specific cases: unreadable/invalid
`pool.json` → refuse to run (never overwrite state we can't parse; tell the
user the path); zero gated runs → "nothing to learn from" no-op; judge output
without a `<verdict>` tag → that example is dropped from the minibatch (and
counted in the report).

## Testing

- Pool: bootstrap-from-seed, round-trip, single-champion invariant, Pareto
  front on crafted score sets (dominated/non-dominated/tie), parent-selection
  weighting, dual-gate truth table (beat-parent × dominated combinations),
  length-cap rejection, corrupt-manifest refusal.
- Evolution: full generation with scripted dispatchers (reflection, mutation,
  judge) — survivor path, gate-fail path, placeholder-drop path, position-bias
  swap, all-ties path, apply/promotion path with status swap + `.bak`.
- Regression: `--generations 1` on an empty pool matches the v1 pilot's
  observable behavior (candidate file written, live prompt untouched).

## Decisions folded in

- Phased graduation: offline judge minibatch now; live shadow A/B named &
  deferred (Kevin may re-prioritize it against other tracks).
- Quality axis = judge win-rate vs champion (fixed reference), gate arm =
  beat parent; both from the same minibatch machinery.
- Cost-to-acceptance is the north star; Slice A's axes are its honest offline
  proxies; the pool schema carries the live fields from day one.
- d069 (native PS, no DSPy) and d070 (human apply) unchanged.
