# Baton unification — Octopus absorb + agents + token-saver

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or subagent-driven-development per task. Steps use checkbox syntax.

**Goal:** One clean Baton spine — remove Octopus overlap, wire token-saver as Efficiency Officer, ship instrument registry wedge.

**Architecture:** Gap-audit approach (#1). Upgrade existing `/baton:*` commands; add only missing engine hooks. Octopus uninstall + doc scrub. Conductor calls `efficiency-lib` before fleet labor.

**Tech Stack:** PowerShell 7, Python 3 (`tools/token_saver/`), fleet.yaml, instruments.yaml, Maestro/Ox Alpha seating.

## Global Constraints

- Ox Alpha heavily for mouth/conductor/diff_apply (baton-d124)
- Efficiency Officer never blocks labor (fail-open)
- No `/octo:*` compatibility aliases
- No private Grimlore → Ox/OpenRouter
- Kevin merges — no auto-merge to master

---

## Phase A — Docs + decouple (shipped)

- [x] **A1** Unified design spec `docs/superpowers/specs/2026-08-23-baton-unify-octopus-agents-token-saver-design.md`
- [x] **A2** Agent hierarchy spec on master
- [x] **A3** `docs/octo-to-baton-map.md`, `docs/agent-stack.md`
- [x] **A4** Bootstrap: Octopus no longer hard-gate; warn + uninstall script
- [x] **A5** README, GUIDE, agent-handoffs, consolidate-routing scrub

## Phase B — Token-saver as Efficiency Officer (shipped)

- [x] **B1** `scripts/efficiency-lib.ps1`
- [x] **B2** `scripts/fleet-efficiency.ps1` + `commands/efficiency.md` + verbs.yaml
- [x] **B3** Conductor `Build-EfficiencyTaskPrompt` wired via `Invoke-EfficiencyAdvise` + `RepoPath`/`RunDir`
- [x] **B4** `.cursor/skills/baton-efficiency/SKILL.md`, `prompts/efficiency-officer.txt`
- [x] **B5** `scripts/test-efficiency-lib.ps1`
- [x] **B6** `references/coding-profiles/{python,pwsh}.md`

## Phase C — Instrument registry wedge (shipped)

- [x] **C1** `references/instruments.yaml` seed rows
- [x] **C2** `scripts/instruments-lib.ps1` read helper + `scripts/test-instruments-lib.ps1`
- [x] **C3** Maestro usable instruments union registry seats (`Get-UsableInstrumentSeats`)

## Phase D — Remove Octopus on box (shipped on firefly)

- [x] **D1** Run `scripts/uninstall-octopus.ps1`
- [x] **D2** `bootstrap.ps1 -Force -NonInteractive`
- [x] **D3** Verify `claude plugin list` has no octo

## Phase E — Officer wedges (mostly on master + this session)

- [x] **E1** Scheduler eligibility in Maestro (`waiting-quota`, `excess_capacity`) — `officers-lib` + `maestro-admit`
- [x] **E2** VRAM officer claims at local dispatch — `conductor-lib` + `officers-lib`
- [x] **E3** Systems inventory under `$BATON_HOME/systems.yaml` — `Get-SystemsInventory` / `fleet-officers systems`
- [x] **E4** Security-researcher scheduled instrument + sliding-scale state — `security-researcher-lib`, `/baton:security-researcher`
- [x] **E5** Gate consensus % — `consensus_pct` on `Invoke-AcceptanceGate` (agreed findings / total)

## Verification

```powershell
pwsh -NoProfile -File scripts/test-efficiency-lib.ps1
pwsh -NoProfile -File scripts/test-instruments-lib.ps1
pwsh -NoProfile -File scripts/test-security-researcher-lib.ps1
pwsh -NoProfile -File scripts/test-officers-lib.ps1
python3 tools/tests/test_token_saver.py
pwsh -NoProfile -File scripts/test-gate-lib.ps1
```
