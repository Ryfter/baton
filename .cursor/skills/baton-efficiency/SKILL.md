---
name: baton-efficiency
description: >-
  Efficiency Officer — token-saver built into Baton. Use before large prompts,
  during /baton:go labor, or when the user wants fewer tokens. Runs local
  context select and state delta; never blocks labor.
disable-model-invocation: false
---

# Efficiency Officer (token-saver)

Built into Baton — **not** a separate zip skill. Deterministic spine under `tools/token_saver/`.

## When to use

- Long chat / large repo context before dispatching Ox or other instruments
- Follow-up that continues accepted work (state delta, not full transcript replay)
- User asks to save tokens or mentions plan limits

## Do it yourself

```bash
# Bounded context packet (no model call)
pwsh -NoProfile -File scripts/fleet-efficiency.ps1 select -Request "what we decided about OIDC" -Root /path/to/repo

# Or via baton verb (after bootstrap)
baton efficiency select -Request "..." -Root /path/to/repo
```

During `/baton:go`, Conductor calls `Build-EfficiencyTaskPrompt` automatically when `-RepoPath` is set.

## Rules

- Never block labor — fail-open on select errors
- Prefer Ox Alpha for planning and diff_apply (baton-d124)
- No private Grimlore bodies into Ox/OpenRouter
- Anti-overengineering: skip saves that cost more than they save

Brief: `prompts/efficiency-officer.txt`  
Map from old Octopus habits: `docs/octo-to-baton-map.md`
