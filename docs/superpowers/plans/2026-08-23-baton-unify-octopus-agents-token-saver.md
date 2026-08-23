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

## Phase A — Docs + decouple (shipped in session)

- [x] **A1** Unified design spec `docs/superpowers/specs/2026-08-23-baton-unify-octopus-agents-token-saver-design.md`
- [x] **A2** Agent hierarchy spec on master
- [x] **A3** `docs/octo-to-baton-map.md`, `docs/agent-stack.md`
- [x] **A4** Bootstrap: Octopus no longer hard-gate; warn + uninstall script
- [x] **A5** README, GUIDE, agent-handoffs, consolidate-routing scrub

## Phase B — Token-saver as Efficiency Officer (shipped in session)

- [x] **B1** `scripts/efficiency-lib.ps1`
- [x] **B2** `scripts/fleet-efficiency.ps1` + `commands/efficiency.md` + verbs.yaml
- [x] **B3** Conductor `Build-EfficiencyTaskPrompt` before `Invoke-TaskViaFleet`
- [x] **B4** `.cursor/skills/baton-efficiency/SKILL.md`, `prompts/efficiency-officer.txt`
- [x] **B5** `scripts/test-efficiency-lib.ps1`
- [x] **B6** `references/coding-profiles/{python,pwsh}.md`

## Phase C — Instrument registry wedge (shipped in session)

- [x] **C1** `references/instruments.yaml` seed rows
- [ ] **C2** `scripts/instruments-lib.ps1` read helper (next PR)
- [ ] **C3** Maestro job rows reference instrument names (next PR)

## Phase D — Remove Octopus on box

- [ ] **D1** Run `scripts/uninstall-octopus.ps1`
- [ ] **D2** `bootstrap.ps1 -Force -NonInteractive`
- [ ] **D3** Verify `claude plugin list` has no octo

## Phase E — Later wedges (same program, separate PRs)

- [ ] **E1** Scheduler eligibility in Maestro (`waiting-quota`, `excess_capacity`)
- [ ] **E2** VRAM officer claims at local dispatch (LRG)
- [ ] **E3** Systems inventory under `$BATON_HOME/systems.yaml`
- [ ] **E4** Security-researcher scheduled instrument + sliding scale state
- [ ] **E5** Council consensus % gate if missing in gate-lib

## Verification

```powershell
pwsh -NoProfile -File scripts/test-efficiency-lib.ps1
python -m pytest tools/tests/test_token_saver.py -q
pwsh -NoProfile -File scripts/uninstall-octopus.ps1
pwsh -NoProfile -File scripts/bootstrap.ps1 -NonInteractive
```
