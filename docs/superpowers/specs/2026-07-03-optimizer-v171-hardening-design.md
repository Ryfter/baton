# Optimizer v1.7.1 hardening — stale re-scoring + shadow-verdict attribution + one-shot promote nudge

**Date:** 2026-07-03 · **Base:** v1.7.0 (PR #74, d072) · **Type:** hardening wave (patch release)

Closes the three loose ends named in the v1.7.0 roadmap and final review: the Slice A
stale-candidate re-scoring deferral, and review findings M2 (verdict attribution) and M1
(promote-event spam). No new features; no schema migration (all additions are additive,
still schema 1).

## Goal

After this ships, the optimizer has no known gaps: a champion swap no longer permanently
darkens the rest of the pool, live-A/B dollars can never be judged against a different
challenger than the one that ran, and the PROMOTE nudge fires once instead of every run.

## Fix 1 — Stale-candidate re-scoring (Slice A deferral)

**Problem.** `-Apply` retires the old champion and nulls `win_rate_vs_champion` on every
other active candidate (scores were measured against the OLD champion). Null-scored
candidates are excluded from the Pareto front (`Get-ParetoFront`), parent selection, and
challenger selection (`Select-ShadowChallenger`) — and nothing ever re-scores them. One
`--apply` and the rest of the pool goes permanently dark.

**Fix.** In `Invoke-PromptEvolution` (scripts/optimize-prompt-lib.ps1), after the pool
loads and `$runs` is gathered, **before the generation loop**: for every candidate with
`status -eq 'candidate'` and `$null -eq $_.offline.minibatch.win_rate_vs_champion`,
re-run `Invoke-MinibatchEval` (candidate text vs current champion text over `$runs`,
using the already-initialized `$PlanDispatcher`/`$JudgeDispatcher`), and overwrite
`$c.offline.minibatch` with the fresh result (`wins/losses/ties/win_rate_vs_champion/examples`).
Then `Save-PromptPool` once for the block.

Rules:
- Champion text loads once before the block (move/duplicate the existing lookup — the
  in-loop lookup at the evaluate step stays as-is).
- Unreadable candidate file → skip that candidate with a `[Console]::Error.WriteLine`
  note; never throw.
- A re-score that yields null win_rate (all dropped/ties — "no evidence") leaves the
  candidate null: honestly stale, still excluded. Do not fabricate a score.
- `Write-Host "Re-scored <id> vs champion <champ>: <wr>"` per candidate (legibility).
- Result contract: add `rescored = @(@{ id; win_rate }, …)` (empty array when none) to
  the returned hashtable. `fleet-optimize-prompt.ps1` prints one line per entry before
  the generation lines: `rescored <id> vs champion: <wr|no evidence>`.
- Spend note: re-scoring costs one minibatch per stale candidate and happens ONLY inside
  explicit `/baton:optimize-prompt` runs — never on the `/baton:go` path. Pool stays
  small by construction (aggressive retirement), so no cap parameter (YAGNI; revisit if
  a pool ever holds >5 stale actives).

## Fix 2 — Shadow-verdict attribution (review M2)

**Problem.** `Complete-Run` accrues dollars to `$assign.variant_id` from `shadow.json`
(resolved at plan time) but then calls `Get-ShadowVerdict`, which re-runs
`Select-ShadowChallenger` at complete time. A fresh evolution between plan and complete
can swap in a different challenger, so the verdict (and a possible auto-retire) evaluates
a challenger other than the one being accrued.

**Fix.** `Get-ShadowVerdict` (scripts/prompt-pool-lib.ps1) gains an optional
`[string]$ChallengerId`:
- Empty/absent → current behavior (`Select-ShadowChallenger`) — CLI `-Pool` report keeps
  showing the live pool's view.
- Provided → resolve that exact id in `$Pool.candidates`; it must exist AND have
  `status -eq 'candidate'`, else return `state='no-challenger'` (the assigned challenger
  is gone — no action this run; self-consistent and fail-open).

`Complete-Run` (scripts/conductor-lib.ps1) passes the assignment:
`Get-ShadowVerdict -Pool $livePool -ChallengerId ([string]$assign.challenger_id)`.
Old `shadow.json` files always carry `challenger_id` (written since v1.7.0); an empty
value degrades to the re-selection path — no new failure mode.

## Fix 3 — One-shot PROMOTE nudge (review M1)

**Problem.** Once a challenger is winning at threshold, every subsequent gated run
re-emits an identical "promote via --apply" event — ~20 duplicates if the human waits 20
runs.

**Fix.** Additive per-candidate field `promote_recommended_at` (UTC `…Z` string, default
`$null`):
- `New-PoolCandidateRecord` creates it as `$null`.
- `Get-PromptPool`'s DateTime re-stringify block MUST cover it (same ConvertFrom-Json
  auto-parse trap as `created`/`retired_at`).
- `Complete-Run` promote branch: emit the event ONLY when the challenger record's
  `promote_recommended_at` is null, then stamp it (`yyyy-MM-ddTHH:mm:ssZ`). The existing
  single `Save-PromptPool` at the end of the accrual block persists it.
- One nudge per candidate, ever. The `-Pool` report footer still shows the live PROMOTE
  verdict on every invocation, so nothing is hidden; only `events.jsonl` noise goes away.
- `-Pool` report: no new column (avoid widening the 14-column table); the verdict footer
  gains `— recommended <stamp>` when the stamp is set.

## Non-goals

- No statistical confidence on the shadow verdict (d072 revisit condition: only if
  threshold-count evidence proves flip-floppy in practice).
- No re-score cap/budget parameter (see Fix 1 spend note).
- No change to promotion authority: promote stays human `--apply` (d070/d072).

## Error handling

House rules throughout: fail-open on the `/baton:go` path (all Fix 2/3 changes live
inside the existing accrual `try/catch`); `[Console]::Error.WriteLine` + skip (never
`Write-Error` under `$ErrorActionPreference='Stop'`) for per-candidate re-score faults;
`utf8NoBOM` for every write; `@()` array wrapping inside hashtable literals; null→''
`[AllowNull()][string]` coercion normalized back to `$null` where JSON null matters
(`promote_recommended_at`).

## Testing (hermetic — temp `BATON_HOME`, save/restore in try/finally)

- **prompt-pool suite:** `New-PoolCandidateRecord` carries `promote_recommended_at=$null`;
  round-trip preserves a stamped value as a `…Z` string (DateTime trap);
  `Get-ShadowVerdict -ChallengerId` overrides selection (assigned beats higher-win-rate
  rival); assigned-but-retired id → `no-challenger`; empty id → re-selection unchanged.
- **optimize-prompt suite:** E16 — pool with a stale (null-wr) active candidate + canned
  dispatchers → after `Invoke-PromptEvolution`, the candidate has a fresh
  `win_rate_vs_champion`, `rescored` names it, and the pool file persists the score even
  when the subsequent generation fails; E17 — unreadable stale-candidate file is skipped
  without aborting the run.
- **conductor suite:** SB11 — two consecutive winning gated runs emit exactly one promote
  event and stamp `promote_recommended_at`; SB12 — pool mutated between plan and
  complete (new higher-wr candidate appended) → verdict still evaluates the assigned
  challenger from `shadow.json`.
- All existing suites stay green (regression gate).

## Release

Patch `1.7.0` → `1.7.1`. Docs: `commands/optimize-prompt.md` (re-scoring paragraph +
one-shot nudge note), `docs/COMMANDS.md` (one-line re-scoring mention). Release notes
`docs/releases/2026-07-03-v1.7.1.md`. Standard gated flow: feature branch → PR → human
merge word → bootstrap deploy. After deploy: the seed step (first real
`/baton:optimize-prompt` evolution run) per Kevin's "hardening, then seed" direction.
