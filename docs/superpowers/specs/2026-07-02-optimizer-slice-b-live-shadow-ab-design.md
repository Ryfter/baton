# Optimizer Slice B — Live Shadow A/B (design)

**Date:** 2026-07-02 · **Status:** approved direction (Kevin, 2026-07-02) ·
**Base:** `2026-07-01-optimizer-graduation-design.md` (Slice A, shipped v1.6.0,
PR #73, d071) · **Depends on:** `scripts/prompt-pool-lib.ps1`,
`scripts/conductor-lib.ps1`, `scripts/cost-resolver-lib.ps1`

## Goal

Close the GEPA loop with live evidence: a gate-surviving candidate becomes the
**challenger**, real `/baton:go` runs alternate champion/challenger, each run's
**CostResolver-metered realized cost** and acceptance-gate verdict accrue to the
variant that produced its plan, and the pool answers promote/retire **in
dollars**. Slice A's offline judge predicted fewer rework loops; Slice B
measures the real thing.

## North-star metric (Kevin, 2026-07-01)

**Total realized cost to an ACCEPTED outcome** — never per-token price. The
per-variant figure is

```
cost_per_accept = live.realized_cost_usd / live.accept        (null when accept = 0)
```

Rework is not a separate estimate: every dollar spent on a run that ended
`polish` or `reject` is *by definition* rework spend and accrues to
`live.rework_cost_usd` as well as the total. A prompt that is cheaper per run
but triggers more rework shows a *worse* cost_per_accept — the Sonnet-vs-Fable
arithmetic, encoded.

## Decisions (Kevin, 2026-07-02)

1. **Shadow is ON by default** whenever an active challenger exists. Kill
   switch: `/baton:optimize-prompt --shadow off` (persisted in `pool.json`;
   absent key = on). Matches the autonomy north star — live evidence starts
   accruing without a prompt from the user.
2. **Auto-retire losers.** At the evidence threshold, a challenger that is
   clearly losing in dollars is retired automatically — it stops burning money
   on real runs. Every retirement (this one and all existing paths) must
   record **why** (the dollars/reason), **when** (UTC timestamp), and **what
   beat / replaced it**.
3. **Promotion stays human** (`--apply`, d070 unchanged). Baton may only act
   autonomously in the safe direction (stop spending); deploying a new live
   prompt always takes the human's word.

## Scope

**In:** shadow assignment in the plan phase; live accrual + auto-retire in
`Complete-Run`; schema additions (`shadow` flag, `retired_at`/`retired_by`);
pool report with the dollars verdict; `--shadow on|off` CLI; tests; docs;
version `1.7.0-rc.1`.

**Non-goals:** optimizing any prompt other than the Conductor planner;
autonomous promotion (d070 stands); any Python/DSPy dependency (d069 stands);
multi-challenger concurrent A/B/n (one challenger at a time); statistical
significance testing (threshold-count evidence is v1 — revisit if verdicts
flip-flop in practice).

## Schema additions (pool.json, still schema 1 — additive, zero-migration)

Top level:

```jsonc
{
  "schema": 1,
  "champion": "p001",
  "shadow": true,            // NEW — kill switch; ABSENT key reads as true
  "candidates": [ ... ]
}
```

Per candidate — two new fields beside the existing `retired_reason`:

```jsonc
{
  "retired_reason": "live A/B loss vs p001: cost_per_accept 4.12 vs 2.30 over 6/7 gated runs",
  "retired_at": "2026-07-08T14:00:00Z",   // NEW — null until retired
  "retired_by": "p001"                    // NEW — variant that beat/replaced it; null for mechanical retirement
}
```

`New-PoolCandidateRecord` creates both new fields as `$null`. Loading a
Slice-A pool (fields absent) is legal — writers add the fields on first
retirement; readers treat absent as null. `live.*` fields are unchanged from
Slice A (created at zero, written only by this slice).

## Design

### 1. One retirement door: `Set-CandidateRetired` (prompt-pool-lib)

```
Set-CandidateRetired -Pool <hashtable> -Id <string> -Reason <string> [-By <string>]
```

Sets `status='retired'`, `retired_reason=$Reason`,
`retired_at=<UTC now, yyyy-MM-ddTHH:mm:ssZ>`, `retired_by=$By` (null when
omitted — mechanical rejections have no victor). Does NOT save the pool (the
caller batches saves, matching Slice A's save-once-per-generation pattern).
**All existing retirement writes in `optimize-prompt-lib.ps1` (placeholder
loss, length cap, gate failure, `superseded` on --apply) are refactored to
call it** — `superseded` passes `-By <new champion id>`.

### 2. Assignment: `Resolve-ShadowVariant` (prompt-pool-lib)

```
Resolve-ShadowVariant [-PoolDir <dir>]
  → @{ shadow=$false; reason='absent'|'corrupt'|'disabled'|'no challenger'|'challenger unreadable' }
  → @{ shadow=$true; variant_id; role='champion'|'challenger'; template; challenger_id }
```

- Pool absent/corrupt → `shadow=$false` (zero-overhead today-behavior).
- `pool.shadow` present and `$false` → `'disabled'`.
- **Challenger selection:** among `status='candidate'` members with non-null
  `win_rate_vs_champion`, the highest win rate; tie → highest id (newest).
  None → `'no challenger'`.
- **Alternation:** compare `live.runs` of champion vs challenger; fewer runs
  takes this run; tie → challenger (it is the one needing evidence). This is
  self-balancing across aborted/ungated runs.
- Champion role: `shadow=$true` with `template=$null` — the caller uses the
  normal live-file resolution chain, so champion runs are bit-identical with
  today. Challenger role: `template` = the pool's `pNNN.txt` text; if the file
  is missing/unreadable or fails the three-placeholder check
  (`{{schema}}`,`{{evi}}`,`{{Goal}}`), fail open to
  `@{ shadow=$false; reason='challenger unreadable' }` — never degrade a real
  run with a broken prompt.
- Never throws; never writes the pool (assignment is not evidence — counters
  move only at accrual).

### 3. Plan-phase wiring (conductor-lib)

- `Build-PlannerPrompt` gains `[string]$Template` — when non-empty AND it
  contains all three placeholders, it is used verbatim; otherwise the existing
  chain (BATON_HOME file → repo file → baked-in default) runs untouched.
- `Invoke-PlanPhase` gains `[scriptblock]$ShadowResolver` (test seam; default
  `{ Resolve-ShadowVariant }`) and `[string]$RunDir`. Before building the
  prompt it resolves the variant; on `shadow=$true` it:
  - passes `-Template` (challenger) or nothing (champion),
  - writes `shadow.json` to `$RunDir`:
    `@{ variant_id; role; challenger_id; assigned='<UTC>' }` (utf8NoBOM),
  - logs an event: `kind='shadow'`,
    message `"prompt variant <id> (<role>) — live A/B vs <other>"` — the
    legibility line.
  On `shadow=$false` it does nothing extra (no event spam on the common path).
  A `$null`/empty `RunDir` skips shadow entirely (library callers without a
  run dir get today's behavior).
- `Invoke-Conductor` passes its `$RunDir` through to `Invoke-PlanPhase`.

### 4. Accrual + auto-retire: `Complete-Run` (conductor-lib)

After the report is rendered (never before — accrual must not delay or break
the user-facing path), wrapped in try/catch with a `warn` event on failure:

- Read `$RunDir/shadow.json`; absent → done (non-shadow run).
- Load the pool; not ok → `warn` event, done.
- Compute the run's realized cost. On a gated run the effective-cost branch
  already computed `Get-RunCost` — reuse that number. On an **ungated** shadow
  run, call `Get-RunCost` here (cost is real even without a verdict).
- `Add-LiveRunResult -Pool $pool -VariantId <id> -CostUsd <n> [-Verdict accept|polish|reject]`
  (prompt-pool-lib): `live.runs += 1`; `live.realized_cost_usd += CostUsd`;
  with a verdict: that counter `+= 1`, and polish/reject also add to
  `live.rework_cost_usd`. No verdict param → cost-only. Mutates, does not save.
- **Auto-retire check** — `Get-ShadowVerdict -Pool $pool` (prompt-pool-lib):

  ```
  → @{ state='insufficient'; ... }   gated(champion) < 5 OR gated(challenger) < 5
  → @{ state='promote'; ... }        challenger cost_per_accept strictly < champion's,
                                     or challenger accept>0 while champion accept=0
  → @{ state='retire'; ... }         challenger worse: higher cost_per_accept, or
                                     challenger accept=0 while champion accept>0
  → @{ state='stalemate'; ... }      both accept=0 at threshold — no dollars
                                     verdict possible; keep gathering, flag in report
  ```

  where `gated(v) = accept+polish+reject`, threshold
  `$script:ShadowMinGatedRuns = 5`, and every shape carries
  `champion_id/challenger_id/cost_per_accept` pairs + gated counts for the
  report. Equal cost_per_accept → `stalemate` (no action on a tie).
- On `state='retire'`: `Set-CandidateRetired` with reason
  `"live A/B loss vs <champ>: cost_per_accept <x> vs <y> over <n>/<m> gated runs"`
  and `-By <champion id>`; log event
  `kind='shadow'`, `level='warn'`, message = the reason. On `promote`: log an
  info `shadow` event recommending `--apply` — **never act**.
- Save the pool once at the end.

### 5. Report + CLI (fleet-optimize-prompt.ps1)

- `-Pool` (and `-Json`) extended: per-variant live columns
  (`runs / accept / polish / reject / realized$ / rework$ / $per-accept`) and
  a **Shadow verdict** footer from `Get-ShadowVerdict`:
  `insufficient (n/5 vs m/5)` · `PROMOTE pNNN — saves $x per accepted outcome (--apply to deploy)`
  · `retired pNNN <date>: <reason>` (read from the retirement fields) ·
  `stalemate — no accepted outcomes on either side after threshold`.
- New `-Shadow <on|off>`: loads the pool, sets `pool.shadow`, saves, prints
  the new state. Errors (pool absent) → `[Console]::Error.WriteLine` + exit 2.
- `commands/optimize-prompt.md` + `docs/COMMANDS.md` document the shadow
  lifecycle; `commands/go.md` gets one line noting runs may carry a
  `shadow` event when a challenger is live.

## Error handling (house rules)

- Everything on the `/baton:go` path is **fail-open**: pool absent/corrupt,
  unreadable challenger text, accrual write failure — the run proceeds
  exactly as today and at most logs one `warn` event. No new exit paths.
- No `Write-Error` (throws under `Stop`); CLI failures use
  `[Console]::Error.WriteLine` + exit 2; all file writes utf8NoBOM.
- Pool mutations follow Slice A's pattern: helpers mutate the in-memory
  hashtable, one `Save-PromptPool` per operation batch.
- The pool remains box-private under `$BATON_HOME` — nothing in it enters the
  knowledge repo or any shared seed.

## Testing (hermetic — never touch real ~/.baton or ~/.claude)

- **prompt-pool-lib:** `Set-CandidateRetired` stamps reason/at/by;
  `Resolve-ShadowVariant` truth table (absent, corrupt, disabled, no
  challenger, unreadable challenger text, placeholder-missing text, champion
  pick on fewer-runs, challenger pick on tie, highest-win-rate challenger
  selection); `Add-LiveRunResult` arithmetic incl. rework attribution and
  cost-only ungated path; `Get-ShadowVerdict` five states incl. accept=0
  asymmetry and the tie→stalemate rule.
- **conductor-lib:** `Build-PlannerPrompt -Template` (valid override wins,
  invalid falls back to chain); `Invoke-PlanPhase` writes `shadow.json` +
  `shadow` event on challenger assignment and nothing on `shadow=$false`;
  `Complete-Run` accrues on gated + ungated shadow runs, auto-retires at
  threshold with correct reason/at/by, and a poisoned pool write leaves the
  run result intact (fail-open) — all via injected `-ShadowResolver`/canned
  gate seams and a hermetic `BATON_HOME`.
- **CLI:** `-Shadow on|off` round-trip; `-Pool` renders live columns and each
  verdict footer state; existing Slice-A suites stay green (regression).
- **Bootstrap:** no changes expected (both libs already deploy) — assert only.

## Decisions folded in

- Shadow ON by default with a persisted kill switch (Kevin 2026-07-02).
- Auto-retire in the safe direction only; promotion always human (d070).
- Every retirement records why/when/what-replaced-it via one helper.
- Alternation by fewer-live-runs, not parity — self-balancing.
- cost_per_accept is the single live decision axis; rework dollars are a
  reported diagnostic, not a second gate axis.
- Threshold = 5 gated runs per variant (constant; revisit-if: verdicts
  flip-flop or runs are too scarce for 5 to accrue in reasonable time).
