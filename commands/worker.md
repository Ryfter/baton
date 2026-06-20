---
description: Run a metered external worker (gh models) through Baton routing and inspect its budget/utilization.
argument-hint: "[run <worker> --prompt \"...\" | status [worker]] [--model M] [--file F] [--dry] [--json]"
---

# /baton:worker

Operator surface for adapter-backed (metered) workers. `run` dispatches through the
fleet and auto-records usage — every real call ticks the Usage Governor and a
rate-limit response is mapped to a worker state (with the reset ETA) so the router
routes around it automatically. `status` shows each metered worker's budget,
utilization, and forecast. Advisory only; never blocks.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-worker.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `run github-models --prompt "summarize this" --model gpt-4o-mini` — metered dispatch.
   - `run github-models --file notes.txt --dry` — preview (dispatches, writes nothing).
   - `status` — table of every metered worker: state, utilization %, forecast status.
   - `status github-models --json` — machine-readable budget/utilization detail.

3. Summarize the result in plain language: the worker's answer, whether it was
   metered (tick recorded), and any state change (e.g. "rate-limited, cooling down
   until …") so the user knows the worker will be auto-skipped until it recovers.
