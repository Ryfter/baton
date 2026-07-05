---
description: Crystallize a recurring memory pattern into a Grimdex rule. No args lists watched candidates (auto-detected); pass an id/signature to flag one. Always a visible write.
argument-hint: [<id|signature>] [-Json]
---

# /baton:memory-promote

Promote a recurring problem→attempt→outcome pattern into Grimdex. With no target it
lists the auto-detected candidates (the watcher); with an id or signature it promotes
that one (the flag path). Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-memory.ps1" promote $ARGUMENTS
```

## Arguments

$ARGUMENTS

## Where promotions land (routing)

When `BATON_GRIMDEX_ROOT` points at a Grimdex working copy, the default
writer routes by the pattern's captured scope + kind:

- universal + avoid → `<root>/universal/mistakes.md`
- universal + prefer → `<root>/universal/winners.md`
- project → `<root>/projects/<project-id>/decision-guidance.md` (id from the
  current folder's git remote, else the folder name)

`BATON_GRIMDEX_ROOT` unset/absent, unknown scope, or any write fault → the
box-private lessons file (`BATON_MEM_LESSONS` or the KB default), plus a
warning — a promotion is never lost. Writes are append-only with a dated
header; committing and pushing Grimdex stays with the human.
