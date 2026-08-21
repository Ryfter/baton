---
name: baton-go
description: >-
  Run Baton Conductor (/baton:go) via fleet-go.ps1 with sane defaults. Use when
  the user says /baton:go, wants a goal planned/executed by the fleet, or asks
  to conduct a project without pasting raw PowerShell.
disable-model-invocation: false
---

# /baton:go

You are the **Conductor** (thin). Mouth/Conductor LM seat defaults to **Ox Alpha** per `baton-d124`. In-project orchestration escalates to **Opus**; plan/sprint-review to **Fable**.

## Auto-route (first step on any ask)

Before planning or running fleet-go:

1. Run `~/.baton/overnight/bin/ensure-conductors.sh` — every registered project has a running Maestro job.
2. **Route** — parse project + task from the user; attach to that project's job. Never ask Kevin to spawn a Conductor.
3. Fan **≥2 Orchestrators** with disjoint claims when the ask implies implementation work.

Contract: `docs/maestro-autoroute.md`

## Load Grimlore

Before planning **baton**, **answerbot**, or **grimlore** work:

- Read `Grimlore/projects/<id>/` plus `universal/environment` and `universal/models`
- **Ask First** before treating agent drafts as verified
- Never send private Grimlore bodies to Ox Alpha / OpenRouter

## Run the engine

From `/Users/kev/Dev/Baton`:

```bash
# source OpenRouter if present (Ox Alpha)
[[ -f ~/.baton/overnight/.openrouter.env ]] && source ~/.baton/overnight/.openrouter.env

pwsh -NoProfile -File scripts/fleet-go.ps1 \
  -Goal "<goal>" \
  -Execute \
  -RepoPath /Users/kev/Dev/Baton \
  -FleetPath "$HOME/.baton/overnight/fleet.yaml" \
  -MaxCostTier paid \
  -Stakes standard \
  -Json
```

Long goals → `-GoalFile` (965-byte argv ceiling).

Flags the user may ask for: `--no-verify` → `-NoVerify`; `--no-plan-gate` → `-NoPlanGate`; `--budget N` → `-Budget N`.

## Parallel dispatch (Maestro standing order)

**Fan Orchestrators wide; never serialize Conductors.**

- One Conductor turn per **project** — admit/fire B and C before A finishes.
- Each Conductor spawns **N Orchestrators** with **disjoint file claims** in the same turn.
- Do not finish project A before starting B/C/D. See `~/.baton/overnight/MAESTRO-PARALLEL.md`.
- Maestro job board: `~/.baton/overnight/swarm/out/MAESTRO-BOARD.md`.

## Afterward

Narrate `run_dir` events tersely. Never merge to master without Kevin. Prefer worktree branches left for review.
