# Officer registry stub (`baton-d133`)

**Status:** stub only — no agents, no dispatch, no sidecar processes.  
**Decision:** `baton-d133` (`Grimdex/projects/baton/decisions/d133-agent-hierarchy-instrument-officers.md`)  
**Spec:** [`docs/superpowers/specs/2026-08-22-agent-hierarchy-instrument-officers-design.md`](superpowers/specs/2026-08-22-agent-hierarchy-instrument-officers-design.md)  
**Schema:** [`docs/officer-registry.schema.json`](officer-registry.schema.json)

This file is the in-repo face of the four standing officers. It does **not** invent new agents. Orchestrators still route **instruments** (fleet rows + `tools.yaml`); officers advise or gate. Implementation wedges stay in the spec §8 — this stub only names the registry shape.

## Hierarchy (locked)

```
Kevin / Mouth (Ox Alpha)
  └─ Maestro (code)
        ├─ Scheduler          (sidecar — eligibility only)
        ├─ VRAM officer       (maestro-adjacent — may briefly queue local GPU)
        ├─ Systems agent      (inventory — never a mutex)
        └─ Conductor (Ox Alpha)
              ├─ Efficiency Officer  (sidecar — never blocks labor)
              └─ Orchestrator(s) → Instruments
```

## Officers

| id | Role | Level | Blocks labor? | Job |
|---|---|---|---|---|
| `scheduler` | Scheduler | Maestro sidecar | Eligibility only | Nested 5h vs week/month windows, Fable ≤1/h, `excess_capacity` tags. Does not admit. |
| `efficiency` | Efficiency Officer | Conductor sidecar | **Never** | Token/process optimize, prompt reuse, lean language profiles, anti-overengineering. Token-watch is a duty, not a separate agent. |
| `vram` | VRAM officer | Maestro-adjacent | **Briefly** (must) | Inventory loaded models; exclusive “1× large” vs shared “N× small”; serialize; prefer warm; TTL unload. Agent face of Local Resource Governor + d043. |
| `systems` | Systems agent | Factory inventory | No | Catalog GPU/NPU/CPU/RAM/Pi/edge; recommend NPU for STT vs GPU for codegen; feed health canary. Discovery ≠ mutex. |

## Do not

- Seat deep security on Fable / Sol
- Let Efficiency Officer block admit
- Thrash-load multiple large local models without VRAM claims
- Add per-language coding *agents* (language is a profile under one coding instrument)
- Treat this stub as a runnable registry — no new processes, no new `/baton:` verbs

## Schema

A future live file (box-private, not this stub) MUST validate against `docs/officer-registry.schema.json`. Required per row: `id`, `role`, `level`, `blocks_labor`. Allowed `id` values are exactly the four above.

Example instance: [`docs/officer-registry.example.json`](officer-registry.example.json).

## Runtime (this worktree)

Code, not chat agents:

| Officer | Library | Wired into |
|---|---|---|
| Scheduler | `scripts/officers-lib.ps1` `Get-SchedulerEligibility` | `scripts/maestro-admit.ps1` (re-evaluates queued / waiting-quota / excess_capacity) |
| Efficiency | `Invoke-EfficiencyAdvise` | `Invoke-TaskViaFleet` (fail-open, never blocks) |
| VRAM | `Request-VramClaim` | local `cost_tier` labor — deny → failover |
| Systems | `Get-SystemsInventory` / `Get-SystemsPlacementAdvice` | `fleet-doctor` text footer; `$BATON_HOME/systems/inventory.json`. GPU GB from nvidia-smi or Apple unified memory; loaded models from LM Studio `/api/v1/models`. |

Language profiles (lean): `references/coding-profiles/` — `Invoke-EfficiencyProfileReview` flags bloat. Security recipe: `Get-SecurityRecipe` + `$BATON_HOME/officers/security-scale.json` (hot/warm/cold; cold requires scheduler residue; never Fable/Sol). Deterministic spine: `Invoke-SecurityScannerSpine`; due orchestration: `Get-SecurityDueProjects` / `Invoke-SecurityDueScans` with optional `-SeedFromRegistry`; LM interpret: `Invoke-SecurityInterpret` (injectable; `-InterpretOnlyOnSignal` on tick). Deep Opus on `-DeepOnResidue` when interpret finds med/high. Quality fold: `Record-SecurityScanQuality` → `model-quality.jsonl`. Maestro tick (`maestro-tick.ps1`) runs `maestro-security.ps1` with registry seed + interpret-on-signal + deep-on-residue. Operator: `fleet-officers.ps1 -Action scan [-Interpret]`. Tests: `scripts/test-officers-lib.ps1` (battery ×5).
