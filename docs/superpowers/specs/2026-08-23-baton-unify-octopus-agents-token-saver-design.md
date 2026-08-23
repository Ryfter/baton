# Baton unified stack — absorb Octopus, integrate agents + token-saver

**Date:** 2026-08-23  
**Status:** approved — Kevin session  
**Implements:** `baton-d133`, Octopus decouple, token-saver as Efficiency Officer  
**Supersedes:** “Octopus adopted as dispatch layer” in `2026-05-22-coding-agent-orchestrator-design.md` for **live** behavior (historical doc kept as archaeology)

## Problem

Baton grew a second dispatch world beside Claude Octopus: `fleet.yaml`, Maestro, `/baton:*`, token-saver scripts, and agent hierarchy decisions (`baton-d133`) all exist, but Octopus still gates bootstrap, docs still call it the dispatch layer, and token-saver ships as a zip/skill beside the engine instead of inside it. Overlap causes conflicts and duct-tape.

## Decision

**One spine. No parallel Octopus world.**

| Layer | Owner |
|---|---|
| Dispatch + routing + gates | Baton (`Invoke-Fleet`, `/baton:route`, Maestro) |
| Multi-model review | `/baton:council`, `/baton:ensemble`, `/baton:six-hats`, `/baton:gate` |
| Factory / dark runs | Maestro + `/baton:go` + job phases |
| Token discipline | **Efficiency Officer** (deterministic `tools/token_saver/` + Conductor hooks) |
| Agent roles | Maestro → Conductor (Ox) → Orchestrator (Opus) → Instruments |
| Octopus plugin | **Removed** — no bootstrap hard-gate, no `/octo:*` aliases |

## Octopus → Baton map (live)

| Octopus | Baton |
|---|---|
| `/octo:auto` | `/baton:route --run`, Maestro auto-route |
| `/octo:council` | `/baton:council` |
| `/octo:debate`, `/octo:multi` | `/baton:ensemble`, `/baton:six-hats` |
| `/octo:research` | `/baton:research`, `/baton:research-gate` |
| `/octo:factory`, DDDD | Maestro + `/baton:go` + job phases |
| `/octo:parallel` | `/baton:code-parallel` |
| `/octo:review`, `/octo:security` | `/baton:gate`, plan/research gates |
| `/octo:doctor`, `/octo:usage`, `/octo:costs` | `/baton:fleet doctor`, `/baton:usage`, `/baton:cost` |
| `/octo:setup` | `scripts/bootstrap.ps1` |
| Personas (32) | Instrument registry + lean coding profiles — not 32 agents |
| Consensus gate | Gate-lib + council synthesis (extend if % quorum missing) |
| `~/.claude-octopus/results` | `$BATON_HOME/runs/`, journal, `consolidate-routing` |

Full table: [`docs/octo-to-baton-map.md`](../../octo-to-baton-map.md).

## Token-saver integration

**Not** a separate optional skill. The Efficiency Officer owns:

1. **`select_context.py`** — bounded passage packet before instrument prompts (no whole-repo paste).
2. **`state_delta.py`** — accepted result + delta across turns (`.token-saver/state.json` in repo or run dir).
3. **Standing brief** — `prompts/efficiency-officer.txt` + `.cursor/skills/baton-efficiency/SKILL.md`.
4. **Engine hooks** — `efficiency-lib.ps1` called from Conductor task dispatch and exposed as `/baton:efficiency`.

Ringer remains optional external pre-gateway; Baton path does not require it.

## Agent stack (built-in)

Canonical hierarchy: [`2026-08-22-agent-hierarchy-instrument-officers-design.md`](2026-08-22-agent-hierarchy-instrument-officers-design.md).

Shipped in this program (wedge 1):

- `references/instruments.yaml` — registry schema + seed rows
- `references/coding-profiles/*.md` — lean language payloads
- `docs/agent-stack.md` — single front door for humans + agents
- Efficiency Officer wired into Conductor
- Octopus removed from bootstrap; `scripts/uninstall-octopus.ps1` for cleanup

Later wedges (same spec, separate PRs): Scheduler eligibility, VRAM officer claims, Systems inventory, security-researcher cadence.

## Default labor seating (Kevin directive)

**Ox Alpha heavily** for mouth, conductor planning, diff_apply grunt, and cheap verify. Opus for orchestration/sprint review. Local LMS for private context. See `baton-d124` and `.cursor/skills/baton-layers/SKILL.md`.

## Done when

1. `bootstrap.ps1` succeeds with Octopus **not** installed.
2. `claude plugin uninstall octo@nyldn-plugins` documented and runnable.
3. README/GUIDE/agent-handoffs no longer require Octopus.
4. Token-saver runs through Efficiency Officer on `/baton:go` labor (when repo path known).
5. `references/instruments.yaml` + coding profiles exist; agent-stack doc is the orientation path.
6. Tests: `test-efficiency-lib.ps1`, `test_token_saver.py` pass.

## Non-goals

- Cloning all 55 `/octo:*` commands
- `/octo:*` compatibility aliases (prolongs overlap)
- Efficiency Officer as admit gate
- Auto-merge or private Grimlore → Ox
