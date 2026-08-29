# /baton:dark-factory

Level-4 dark factory — queue overnight Maestro lanes while Kevin sleeps.

## Lanes (default)

| Lane | Project | What |
|---|---|---|
| `dashboard` | baton | Dark Factory dashboard panel + HTMX partial |
| `baton-spine` | baton | Automation scripts + night runner |
| `grimdex-edu-curriculum` | grimdex-edu | Ship Learn pages from curriculum backlog |

## Commands

```powershell
# Queue lanes (skip if already active)
pwsh -NoProfile -File scripts/fleet-dark-factory.ps1 -Action seed -Admit -Json

# Status for dashboard / CLI
pwsh -NoProfile -File scripts/fleet-dark-factory.ps1 -Action status -Json

# Full night tick: seed → admit → fire → maestro-watch once
./scripts/dark-factory-night.sh
```

## Grimdex-edu curriculum

Backlog: `Grimdex-edu/learn/curriculum-backlog.yaml`  
Audit: `pwsh -NoProfile -File scripts/curriculum-audit.ps1 -Json`  
Roadmap: `Grimdex-edu/docs/curriculum-roadmap.md`

## Rules

- Ox Alpha for labor; no auto-merge to master
- Worktrees: `WT-<project≤7>-<goal-slug>` under `.baton-worktrees/`
- Branches: `baton/run-<run-id>` left for human review
- **Context windows:** maintain aggressively on long runs — handoff-first prompts, Efficiency select/delta before each dispatch, fresh orchestrator per claim, fold completed work to `report-<project>.md`
## Observability

- **Observability:** optional AgentTrail sidecar per active worktree + AgentPulse snapshot for stuck/drift on the Home rail — see [`docs/agent-observability.md`](../docs/agent-observability.md)
- Seed fail-open starts AgentTrail (`BATON_AGENTTRAIL=0` to skip); night runner fail-open refreshes AgentPulse snapshot

```powershell
# Start live map on a factory lane (registry project id + folder)
pwsh -NoProfile -File scripts/fleet-agenttrail.ps1 -Action start -Project baton -Json

# Refresh trajectory snapshot for the dashboard
pwsh -NoProfile -File scripts/fleet-agenttrail.ps1 -Action snapshot -Json
```

```powershell
# Push standing order + handoffs to every active thread
pwsh -NoProfile -File scripts/fleet-dark-factory.ps1 -Action broadcast -Json
```
