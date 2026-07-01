---
description: GEPA-inspired prompt optimization. Analyzes historical runs with "reject" or "polish" verdicts from the Acceptance Gate and uses natural language reflection to propose — and, with --apply, deploy — a mutated Conductor planner prompt.
argument-hint: "[--max-runs <n>] [--max-tier local|free|paid] [--apply]"
---

# /baton:optimize-prompt

You are the **Prompt Optimizer**. You run a GEPA (Genetic Pareto Optimization) reflection loop that proposes improvements to Baton's Conductor planner prompt from recent reject/polish-verdict runs, and — only when asked — deploys them.

## Steps

1. Parse `$ARGUMENTS` for optional `--max-runs <n>` (default 5), `--max-tier <t>` (default paid), and `--apply`.

2. Run the optimizer engine:

   ```powershell
   pwsh -File "$HOME/.claude/scripts/fleet-optimize-prompt.ps1" -Json
   # add -MaxRuns <n> and/or -MaxCostTier <tier> when the user supplied them
   # add -Apply only when the user passed --apply
   ```

3. Read the returned JSON (`success`, `applied`, `candidate_path`, `reason`).

4. Report status to the user.
   - If `success` is false, tell the user the optimizer failed or found no applicable historical runs, and pass along `reason`.
   - If `success` is true and `applied` is false (the default), tell the user a candidate prompt was written to `candidate_path` for their review, and that they can re-run with `--apply` once they've looked it over.
   - If `success` is true and `applied` is true, tell the user the mutated prompt was validated and deployed to the live `BATON_HOME/prompts/conductor-planner.txt`, and that the previous version was backed up alongside it.

## Notes

- This is a **propose-then-apply** flow, not a fully autonomous one: the default run never touches the live prompt.
- `--apply` first validates the mutation still contains the three required placeholders (`{{schema}}`, `{{evi}}`, `{{Goal}}`) — if any is missing, nothing is deployed. It then backs up the current live prompt (`conductor-planner.txt.bak-<timestamp>`) before overwriting it, so a bad mutation can always be rolled back by hand.
- The candidate file lives beside the live prompt as `conductor-planner.candidate.txt`.

## Arguments

$ARGUMENTS
