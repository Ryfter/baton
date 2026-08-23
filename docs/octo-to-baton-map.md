# Octopus → Baton command map

**Status:** live after 2026-08-23 unification. Octopus is **not** required.

Use `/baton:*` only. If a workflow still mentions `/octo:*`, translate using this table.

## Core dispatch

| Was (Octopus) | Now (Baton) |
|---|---|
| `/octo:auto "…"` | `/baton:route --run "…"` or `/baton:go "…"` |
| `/octo:quick` | `/baton:route` (advise) or short `/baton:go` |
| `/octo:model-config` | `~/.baton/fleet.yaml` + `/baton:models` |

## Multi-model review

| Was | Now |
|---|---|
| `/octo:council` | `/baton:council` |
| `/octo:debate` | `/baton:ensemble` or `/baton:six-hats` |
| `/octo:multi` | `/baton:ensemble` |
| `/octo:review` | `/baton:gate` |
| `/octo:security` | `/baton:gate` + security scanners (future instrument) |
| `/octo:staged-review` | `/baton:plan-gate` then `/baton:gate` |

## Factory / pipeline

| Was | Now |
|---|---|
| `/octo:factory` | Maestro watch + `/baton:go --execute` |
| `/octo:pipeline` | `/baton:go` (DAG) |
| `/octo:discover` … `/octo:deliver` | Job phases: `/baton:job-start`, `/baton:job-phase` |
| `/octo:plan`, `/octo:spec`, `/octo:prd` | `/baton:go` planning + `/baton:plan-gate` |
| `/octo:parallel` | `/baton:code-parallel` |
| `/octo:dev`, `/octo:develop` | `/baton:go --execute` |

## Ops

| Was | Now |
|---|---|
| `/octo:doctor` | `/baton:fleet doctor` |
| `/octo:usage`, `/octo:costs` | `/baton:usage`, `/baton:cost` |
| `/octo:setup` | `pwsh scripts/bootstrap.ps1` |
| `/octo:research` | `/baton:research`, `/baton:research-gate` |

## Token / context (was Octopus skill-adjacent)

| Was | Now |
|---|---|
| token-saver skill (zip) | **Efficiency Officer** — `/baton:efficiency`, `tools/token_saver/`, Conductor auto-shrink |
| Manual context paste | `scripts/fleet-context-select.ps1` |

## Drop (no Baton equivalent needed)

| Octopus | Why drop |
|---|---|
| `/octo:claw`, OpenClaw bridges | Out of Baton scope unless adopted as instrument |
| `/octo:freeze` / `/octo:unfreeze` | Baton usage governor + `/baton:usage` |
| `/octo:whats-new` | `docs/roadmap.md`, releases |
| 32 persona agents | Instrument registry + coding profiles |

## Remove Octopus

```powershell
pwsh -NoProfile -File scripts/uninstall-octopus.ps1
```

Then re-run bootstrap:

```powershell
pwsh -NoProfile -File scripts/bootstrap.ps1 -Force -NonInteractive
```
