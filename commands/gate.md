---
description: Run a competitive acceptance review of a work artifact and get an accept/polish/reject verdict with findings and a polish brief.
argument-hint: "run --task \"...\" [--file F | --diff <range> | --artifact \"...\"] [--reviewers a,b] [--json]"
---

# /baton:gate

The after-work quality gate. Feed it a finished artifact (a file, a git diff, or
piped text) and what it was supposed to do; Baton runs a competitive review (≥2
reviewers review independently), reconciles their findings (deduped, tagged agreed
vs solo, severity-weighted), and returns a verdict: **accept** (ship the cheap
artifact as-is), **polish** (a premium pass should fix the listed findings — a
ready-to-use polish brief is emitted), or **reject** (a critical defect). Advisory
only; never blocks and never auto-runs the polish pass.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-gate.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `run --task "add retry to the fetch helper" --diff HEAD~1` — review the last commit's diff.
   - `run --task "summary memo" --file draft.md` — review a file.
   - `run --task "..." --file x.ps1 --reviewers codex,opus --json` — explicit reviewer pair, machine-readable.

3. Summarize in plain language: the verdict and why, the agreed-vs-solo findings,
   and — when the verdict is polish — hand the polish brief to whoever (operator or
   `/baton:go` Conductor) will run the premium pass.
