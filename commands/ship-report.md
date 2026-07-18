---
description: Per-PR ship report — end-to-end cost, quality, and choreography card assembled from journals + git + gh.
argument-hint: "[<pr-number> | --all] [-Branch <name>] [-RunDir <path>] [--json] [--post]"
---

# /baton:ship-report

One **ship-report card** per merged PR: build / review / fix / verification token
costs (exact vs estimate never summed silently), findings confirmed-rate, wall-clock,
and outcome — folded from data Baton already journals. No new instrumentation.

Observe-first (d078): the card is written under the run dir; posting it as a PR
comment is **off** unless you pass `--post`.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-ship-report.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `<pr-number>` — card for that PR (uses `gh` for meta + review comments, `git`
     for branch lifetime/commits, journals under `$BATON_HOME`).
   - `-Branch <name>` — WIP view when there is no PR yet (or PR meta is unavailable).
   - `-RunDir <path>` — fold decisions.jsonl / effective-cost.json from a specific run.
   - `--all` — trend table (one row per previously written `ship-report.json` under
     `$BATON_HOME/runs`).
   - `--json` — machine-readable card (or card array with `--all`).
   - `--post` — also publish the card as a PR comment (default **off**).

3. Summarize in plain language: total tokens by basis, confirmed-rate (or n/a),
   wall-clock, and any honest gaps (conductor overhead is always `not tracked` in
   slice 1; post-merge defects fill in later).
