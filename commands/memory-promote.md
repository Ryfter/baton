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
