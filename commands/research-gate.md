---
description: Research Gate — build/adopt/adapt verdict before non-trivial work. Grounds a cheap governed-fleet model in real evidence (local registry + prior ensemble + KB + optional --deep live search). Recommend-only.
argument-hint: (--text "<task>" | --url <issue> | --file <path>) [--deep] [--json] [--out PATH]
---

# /baton:research-gate

Run the Research Gate over a task and emit a build/adopt/adapt/inconclusive verdict.
With an active job, the memo writes to that job's `phases/research/`; otherwise it
prints to stdout. Reads the latest research ensemble `synthesis.md` as evidence.

Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-research-gate.ps1" $ARGUMENTS
```

## Arguments

$ARGUMENTS
