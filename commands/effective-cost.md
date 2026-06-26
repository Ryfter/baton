---
description: Show the per-worker effective-cost leaderboard — cheapest quality-adjusted worker first, folded from run records. Advisory only.
argument-hint: "[report] [--json] [--runs <glob>] [--min-confidence-runs <n>]"
---

# /baton:effective-cost

The learned cost-vs-quality scoreboard. Each `/baton:go` run that passes through
the acceptance gate writes an `effective-cost.json` record (`effective_cost =
realized_cost ÷ realized_quality` — what you actually paid for the quality you
got, lower is better). This command folds those per-run records into a
**per-worker leaderboard**, ranked cheapest-quality-adjusted first, so you can
see which workers reliably deliver acceptable quality cheaply and which look
cheap on paper but cost more once rejects and polish rounds are counted.

Whole-run, single-producer-weighted attribution: a worker that did one task in a
mixed run is credited by its cost share, not condemned for the rest. `confidence`
rises with run count and the fraction of clean single-producer runs; low-confidence
rows are flagged **tentative**. Advisory / legibility only — it never changes
routing.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-effective-cost.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `report` — print the leaderboard across all runs under `$BATON_HOME/runs`.
   - `report --json` — machine-readable rows (the shape the dashboard MODEL
     LEADERBOARD panel consumes).
   - `report --runs "D:/some/runs/*/effective-cost.json"` — fold an explicit set.
   - `report --min-confidence-runs 8` — require more runs before a row reads as
     fully confident.

3. Summarize in plain language: who the cheapest-quality-adjusted worker is, which
   rows are still tentative (and why — too few clean runs), and any worker that
   looks cheap by tier but ranks poorly once quality is folded in.
