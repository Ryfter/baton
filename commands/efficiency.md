---
description: Efficiency Officer — bounded context select and state delta (token-saver built in). select|delta-packet|profile|brief.
argument-hint: select "request" [-Root path] | delta-packet -Change "..." | profile -Language python | brief
---

# /baton:efficiency

Efficiency Officer sidecar. Shrinks prompts **without** blocking labor.

## Subcommands

### `select "request" [-Root path]`

Run local passage selection (`tools/token_saver/select_context.py`). Prints bounded context to stdout.

```powershell
pwsh -NoProfile -File scripts/fleet-efficiency.ps1 select -Request "npm OIDC release workflow" -Root D:\Dev\baton
```

### `delta-packet -Change "..."`

Build a follow-up packet from `.token-saver/state.json` when prior work was accepted.

### `profile -Language python|pwsh|...`

Print lean coding profile from `references/coding-profiles/`.

### `brief`

Print standing officer brief (`prompts/efficiency-officer.txt`).

## Auto during `/baton:go`

When `-RepoPath` is set, Conductor uses `Build-EfficiencyTaskPrompt` before each fleet labor call.

## Octopus

Do not use `/octo:*` or the zip skill. See `docs/octo-to-baton-map.md`.
