---
description: Run a competitive acceptance review of a work artifact and get an accept/polish/reject verdict with findings and a polish brief.
argument-hint: "run --task \"...\" [--file F | --diff <range> | --artifact \"...\"] [--reviewers a,b | --panel] [--fail-loud] [--json]"
---

# /baton:gate

The after-work quality gate. Feed it a finished artifact (a file, a git diff, or
piped text) and what it was supposed to do; Baton runs a competitive review (≥2
reviewers review independently), reconciles their findings (deduped, tagged agreed
vs solo, severity-weighted), and returns a verdict: **accept** (ship the cheap
artifact as-is), **polish** (a premium pass should fix the listed findings — a
ready-to-use polish brief is emitted), or **reject** (a critical defect). Advisory
only; never blocks and never auto-runs the polish pass.

Pass `--panel` to run the named roles from `$BATON_HOME/review-roles.yaml`;
when that roster exists and `--reviewers` is omitted, panel mode is selected
automatically. Each role is routed to the cheapest review-capable model allowed
by its `cheap` or `strong` tier, and findings are tagged with the role name.
`--fail-loud` surfaces skipped roles or an entirely unparseable panel as
`degraded: true` in the result for golden-path callers. Without it, the gate
keeps its advisory fail-open behavior.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-gate.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `run --task "add retry to the fetch helper" --diff HEAD~1` — review the last commit's diff.
   - `run --task "summary memo" --file draft.md` — review a file.
   - `run --task "..." --file x.ps1 --reviewers codex,opus --json` — explicit reviewer pair, machine-readable.
   - `run --task "..." --diff HEAD --panel --fail-loud --json` — named panel with degradation surfaced to a caller.

3. Summarize in plain language: the verdict and why, the agreed-vs-solo findings,
   and — when the verdict is polish — hand the polish brief to whoever (operator or
   `/baton:go` Conductor) will run the premium pass.

## Coach footer

Non-JSON output may end with one `Next: <command>` line from the guided-use
coach — a read-only, zero-model-cost suggestion driven by local state (gate
verdicts, prompt-pool evidence, budget posture). Each suggestion appears once
per triggering state. Set the level in `$BATON_HOME/coach/config.json`
(`{"level":"off"|"quiet"|"teach"}`, default `quiet`; `teach` adds the why).
Relay the footer to the user verbatim when present.
