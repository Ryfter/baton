# Effective Cost — Slice 2 (per-worker leaderboard) Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the per-worker learned effective-cost leaderboard — fold the
per-run `effective-cost.json` records into a ranked, confidence-gated table and
expose it as `/baton:effective-cost`. Advisory/legibility only.

**Architecture:** Slice 1 already wrote the join artifact (`effective-cost.json`
per run) and — in the working tree, uncommitted — the pure fold
(`Get-WorkerEffectiveCost`) plus the band-boundary fix (Task 0). This plan adds
the read+print surface over that fold and ships the lot as one task group, then
cuts the v1.4.0 release.

**Tech Stack:** PowerShell pure-lib + seamed-CLI; hermetic Check-harness tests.

## Global Constraints

- **Box-private:** `effective-cost.json` records live under `$BATON_HOME/runs/`;
  they carry worker names + budget-adjacent figures and NEVER go to the
  knowledge repo or any shared seed. `references/fleet.yaml` untouched.
- **Pure lib stays I/O-free** — all inputs are parameters. Reads (run-dir glob)
  live in the CLI behind a `-RunsRoot` param for hermetic testing.
- **Advisory only** — no routing change, no side effects. The confidence-gated
  `Select-Capability` re-rank stays a named, deferred future slice.
- **PowerShell traps:** no param/local named `$args`/`$input`/`$event`/`$matches`/`$host`;
  parenthesize function calls inside comparisons; guard the unary-comma array
  flatten on empty collections; CLI user-error paths use
  `[Console]::Error.WriteLine()` + `exit 2` (not `Write-Error; exit 2`).
- Files written `utf8NoBOM`. Tests never touch real `~/.baton` / `~/.claude`.
- **Plugin:** `.claude-plugin/plugin.json` → `1.4.0-rc.4`, then the v1.4.0
  release promotes it to `1.4.0`.

---

## Already in the working tree (committed-to-disk, uncommitted-to-git; verified green E1–E40)

- **Task 0 — band-boundary fix:** `effective-cost-lib.ps1` `Get-QualityScalar`
  now makes the lower bands half-open at report precision
  (`if ($v -ne 'accept') { $hi = [math]::Max($lo, $hi - 0.0001) }`) and clamps
  in-band (`if ($q -lt $lo) { $q = $lo }`). Tests E2 → `0.6999`, new E6b
  (worst accept > clean polish) + E6c (saturated polish floors at 0.3).
- **The fold — `Get-WorkerEffectiveCost`** (whole-run, single-producer-weighted,
  confidence-gated) + tests E34–E40.

This plan commits those alongside the new surface below.

## Task 1: Leaderboard formatter (pure)

**Files:**
- Modify: `scripts/effective-cost-lib.ps1` (add `Format-EffectiveCostLeaderboard`)
- Test: `scripts/test-effective-cost-lib.ps1` (E41+)

**Interfaces:**
- Produces: `Format-EffectiveCostLeaderboard -Rows <array> [-RunCount <int>] → [string]`.
  Rows are `Get-WorkerEffectiveCost` output (`worker; n_runs; eff_cost_mean;
  single_producer_runs; confidence`). Cheapest-first order is preserved from the
  fold (do not re-sort). Empty rows → a one-line "no records" guidance string.
  Low-confidence rows (`confidence -lt 0.5`) carry a `tentative` marker.

## Task 2: CLI surface

**Files:**
- Create: `scripts/fleet-effective-cost.ps1`
- Create: `commands/effective-cost.md`

**Interfaces:**
- `fleet-effective-cost.ps1 [report] [-Json] [-Runs <glob>] [-MinConfidenceRuns <int>]
  [-RunsRoot <path>]`. Default subcommand `report`; default `RunsRoot =
  $BATON_HOME/runs` (fallback `~/.baton/runs`). Reads `*/effective-cost.json`
  under the root (or an explicit `-Runs` glob), folds via
  `Get-WorkerEffectiveCost`, prints `Format-EffectiveCostLeaderboard`; `-Json`
  emits the raw rows array (the shape the future dashboard MODEL LEADERBOARD
  panel consumes). Unknown subcommand → `exit 2`. A malformed record is skipped
  (try/catch), never fatal.

## Task 3: Hermetic CLI test

**Files:**
- Create: `scripts/test-fleet-effective-cost.ps1`

**Interfaces:**
- Child-process invocation against a temp `RunsRoot` seeded with fixture
  `effective-cost.json` files: `report` ranks cheapest-first; `--json` round-trips
  to an array; empty root → guidance string + exit 0; malformed record skipped.

## Task 4: Bootstrap + plugin bump

**Files:**
- Modify: `scripts/bootstrap.ps1` (manifest array — add `fleet-effective-cost.ps1`;
  `effective-cost-lib.ps1` already present from slice 1)
- Modify: `scripts/test-bootstrap.ps1` (assert `fleet-effective-cost.ps1` deploys)
- Modify: `.claude-plugin/plugin.json` → `1.4.0-rc.4`

## Task 5: Gates → review → ship → v1.4.0

- Run `test-effective-cost-lib.ps1`, `test-fleet-effective-cost.ps1`,
  `test-conductor-lib.ps1`, `test-bootstrap.ps1` — all green.
- Final adversarial whole-branch review (most-capable model).
- Commit, PR, gated merge; bootstrap deploy + live smoke.
- Cut **v1.4.0**: promote plugin `1.4.0-rc.4 → 1.4.0`, release notes
  (`docs/releases/2026-06-25-v1.4.0.md` — saturation d057 + acceptance-gate
  wiring d058 + effective-cost d059 slices 1+2), annotated tag, GitHub release.
