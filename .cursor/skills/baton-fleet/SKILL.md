---
name: baton-fleet
description: >-
  Operate Baton's multi-model fleet via short verbs (doctor, list, test, dispatch,
  status, stop) instead of raw fleet-go.ps1. Use when the user says /baton:fleet,
  wants overnight multi-lane dispatch, Ox Alpha/OpenRouter seating, or fleet health.
disable-model-invocation: false
---

# /baton:fleet

You are the **Maestro mouth** for fleet ops. Prefer Ox Alpha for talk; never invent Claude labor when Kevin forbade it. Layer seating is `baton-d124`.

## Repo + home

- Baton clone: `/Users/kev/Dev/Baton` (or workspace `Baton/`)
- Engine scripts: `Baton/scripts/*.ps1` (prefer repo scripts over `$HOME/.claude/scripts`)
- Live fleet: `~/.baton/fleet.yaml`
- Overnight / multi-lane: `~/.baton/overnight/` (fleet.yaml, goals/, fleet-dispatch.sh)
- OpenRouter key (box-private): source `~/.baton/overnight/.openrouter.env` when present — never print it

## Subcommands

Parse the user text after `/baton:fleet`:

### `doctor [--live]`

```bash
pwsh -NoProfile -File /Users/kev/Dev/Baton/scripts/fleet-doctor.ps1 -Live
```

(omit `-Live` if they did not ask for canaries)

### `list`

```bash
pwsh -NoProfile -Command '. /Users/kev/Dev/Baton/scripts/fleet-lib.ps1; Read-Fleet -Path "$HOME/.baton/fleet.yaml" | Select-Object name,kind,enabled,cost_tier | Format-Table -AutoSize'
```

For overnight roster, use `-Path "$HOME/.baton/overnight/fleet.yaml"`.

### `test <name> "<prompt>"`

Use `Invoke-Fleet` via `fleet-ask.ps1` or fleet-lib — keep prompts out of argv when large (temp file / stdin).

### `dispatch`

Start (or confirm) the multi-lane overnight factory:

```bash
rm -f ~/.baton/overnight/STOP
bash ~/.baton/overnight/fleet-dispatch.sh
```

Lanes: `goals/01-harness.md`, `02-portal.md`, `03-memory-grimlore.md`.

### `status`

```bash
cat ~/.baton/overnight/fleet-status.json
tail -n 40 ~/.baton/overnight/fleet-dispatch.log
tail -n 20 ~/.baton/overnight/lanes/*.log
```

### `stop`

```bash
touch ~/.baton/overnight/STOP
```

Current hops finish; loops exit between rounds.

## Layer seating (do not freelance)

| Layer | Seat |
|---|---|
| Mouth / Composer / Conductor talk | Ox Alpha (`openrouter-glm` / `stealth/ox-alpha`) |
| Orchestrator (in-project) | Opus (`cursor-opus`) |
| Plan + sprint-review | Fable (`cursor-fable`) — needs Cursor data-policy ack |
| Instruments | Ox Alpha diff_apply + Codex/Grok/Kiro/Cursor agentic |

If Fable errors on data policy, say so once and continue with Opus coordinating + Codex peer review — do not silently skip review forever.
