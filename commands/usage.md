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

## Copilot Credits panel (d079)

When the `gh-copilot` fleet entry carries a `budget` (your monthly AI-credit
allowance), `status` appends a Copilot Credits panel: used / allowance / % /
~dollar spend, a cycle-anchored run-rate with days-to-exhaustion, the per-model
split (the finest granularity GitHub exposes for a personal account), and a
warning once usage crosses `credit_warn_pct` (default 80). No `budget` → the
panel (and the fetch) never runs. `--json` adds the same data under
`copilot_credits`.

Box-private fields on the `gh-copilot` entry in `~/.baton/fleet.yaml`:

- `budget: 1500` — monthly allowance in credits (1 credit = $0.01)
- `credit_reset_day: 10` — billing-cycle reset day-of-month (1–28)
- `credit_warn_pct: 80` — optional warn threshold

Auth: rides the ambient `gh` login; the endpoint needs the token to carry the
`user` scope — if missing, the panel shows the exact fix
(`gh auth refresh -h github.com -s user`). `BATON_GH_BILLING_TOKEN` (a PAT) is
the headless fallback. All failures collapse to one honest
`Copilot Credits — unavailable (<reason>)` line; the panel never changes the
command's exit code.

## Coach footer

Non-JSON output may end with one `Next: <command>` line from the guided-use
coach — a read-only, zero-model-cost suggestion driven by local state (gate
verdicts, prompt-pool evidence, budget posture). Each suggestion appears once
per triggering state. Set the level in `$BATON_HOME/coach/config.json`
(`{"level":"off"|"quiet"|"teach"}`, default `quiet`; `teach` adds the why).
Relay the footer to the user verbatim when present.
