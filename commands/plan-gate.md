---
description: Run a competitive review of a plan (task DAG) before any labor runs and get an accept/revise/reject verdict with findings and a revise brief.
argument-hint: "run --goal \"...\" --plan <path\\to\\plan.json> [--reviewers a,b] [--json]"
---

# /baton:plan-gate

The before-work quality gate. Feed it a plan (a task DAG about to be executed
by fleet models) and the goal it's meant to accomplish; Baton runs a
competitive review (≥2 reviewers, independent), reconciles their findings
(deduped, tagged agreed vs solo, severity-weighted), and returns a verdict:
**accept** (run the plan as-is), **revise** (fix the listed findings before
running — a ready-to-use revise brief is emitted), or **reject** (a critical
defect — the plan will fail, damage something, or build the wrong thing).
Advisory only, standalone; never blocks and never auto-revises the plan.
Sibling of `/baton:gate` (the Acceptance Gate), which reviews finished work
instead of a not-yet-executed plan.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-plan-gate.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `run --goal "migrate the billing service to v2" --plan plan.json` — review a plan file with the default reviewer roster (providers claiming the `plan-review` capability).
   - `run --goal "..." --plan plan.json --reviewers codex,opus --json` — explicit reviewer pair, machine-readable.

3. Exit codes (advisory signal for scripts): `0` on verdict `accept`; `1` on
   verdict `revise` or `reject`; `2` on a CLI usage error (missing/unknown
   flag, missing plan file).

4. Summarize in plain language: the verdict and why, the agreed-vs-solo
   findings, and — when the verdict is revise or reject — hand the revise
   brief to whoever (operator or `/baton:go` Conductor) will fix the plan
   before it runs.

See `docs/superpowers/specs/2026-07-10-plan-gate-design.md` (d080) for the
full design.

## Coach footer

Non-JSON output may end with one `Next: <command>` line from the guided-use
coach — a read-only, zero-model-cost suggestion driven by local state. Each
suggestion appears once per triggering state. Set the level in
`$BATON_HOME/coach/config.json` (`{"level":"off"|"quiet"|"teach"}`, default
`quiet`; `teach` adds the why). Relay the footer to the user verbatim when
present.
