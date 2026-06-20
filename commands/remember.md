---
description: Capture a problem→attempt→outcome into Baton's dev memory so recall can warn before you repeat a known-bad fix. Box-private, advisory.
argument-hint: -Problem "<p>" [-Approach "<a>"] [-Outcome pass|fail|partial|unknown] [-Tags a,b] [-Scope project|universal] [-RefJob <id>]
---

# /baton:remember

Append a problem→attempt→outcome row to the box-private memory journal. Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-memory.ps1" remember $ARGUMENTS
```

## Arguments

$ARGUMENTS
