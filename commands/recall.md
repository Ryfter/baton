---
description: Before starting a task, check Baton's dev memory for prior attempts on the same problem — warns when a past fix failed. --deep adds semantic KB neighbors. Advisory.
argument-hint: (-Text "<task>" | -File <path>) [-Deep] [-Json]
---

# /baton:recall

Warn if a task matches a past attempt (especially a known-bad fix). Deterministic
signature match always; `-Deep` adds semantic KB discovery. Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-memory.ps1" recall $ARGUMENTS
```

## Arguments

$ARGUMENTS
