---
description: Inspect and govern worker availability — lockouts, reset ETAs, conserve mode, and usage forecast.
argument-hint: "[status|lockout|limit|cooldown|clear|conserve|tick|forecast] [worker] [...]"
---

# /baton:usage

Operator surface for the Usage Governor. Reads/writes `usage-journal.jsonl` in
BATON_HOME and reports each worker's availability state. Route-around-exhausted is
enforced automatically inside the router (`Select-Capability`); this command is how
you set and inspect that state.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-usage.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `status` — table of every worker: state + ETA/reason + the conserve flag.
   - `lockout <worker> --reset +5h --reason "weekly cap"` — mark exhausted until a reset.
   - `limit <worker>` — soft cap (down-ranked, still selectable unless conserve is on).
   - `cooldown <worker> --until +20m` — short transient backoff.
   - `clear <worker>` — return to available.
   - `conserve on|off` — global posture; biases routing cheaper and hard-stops `limited` workers.
   - `tick <worker> --count N` — record a usage observation (feeds the forecast).
   - `forecast [<worker>]` — best-effort run-rate / days-to-exhaustion.

3. Summarize the resulting state to the user in plain language (which workers are
   available, which are waiting and for how long, and whether conserve mode is on).
