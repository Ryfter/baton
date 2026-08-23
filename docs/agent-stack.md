# Baton agent stack — one spine

**Read this first** when orienting to Baton labor. Octopus is **not** part of the stack.

## Hierarchy

```
Kevin
  Mouth (Ox Alpha) — talk, compose, cheap planning
    Maestro (code) — admit / fire only
      Scheduler · VRAM · Systems (officers)
      Conductor (Ox Alpha) — goal → task DAG
        Efficiency Officer — token-saver, lean prompts (never blocks)
        Orchestrator (Opus) — route instruments, gates
          Instruments — fleet rows + tools.yaml (many concurrent)
```

Deep spec: [`docs/superpowers/specs/2026-08-22-agent-hierarchy-instrument-officers-design.md`](superpowers/specs/2026-08-22-agent-hierarchy-instrument-officers-design.md).

## Where things live

| Concern | Path |
|---|---|
| Fleet roster | `~/.baton/fleet.yaml` |
| Tools | `~/.baton/tools.yaml` |
| Instrument registry | `references/instruments.yaml` |
| Coding profiles | `references/coding-profiles/` |
| Token-saver engine | `tools/token_saver/` |
| Efficiency CLI | `scripts/fleet-efficiency.ps1`, `scripts/efficiency-lib.ps1` |
| Maestro jobs | `~/.baton/maestro/jobs/` |
| Run artifacts | `~/.baton/runs/` |
| Layer seating | `~/.baton/overnight/LAYER-SEATING.md`, `.cursor/skills/baton-layers/` |

## Default seats (Kevin)

1. **Ox Alpha** — mouth, conductor, diff_apply grunt, cheap verify  
2. **Grok / Codex / Kiro / Cursor** — agentic file edits when Ox cannot  
3. **Local LMS / Ollama** — private context, no cloud  
4. **Opus** — orchestration, sprint review  
5. **Fable** — ≤1/h bundle gate only  

## Front doors

| Intent | Command |
|---|---|
| Ship something | `/baton:go "…"` |
| Route one need | `/baton:route --run "…"` |
| Overnight factory | `/baton:fleet dispatch` (Maestro) |
| Multi-model review | `/baton:council`, `/baton:ensemble` |
| Shrink context | `/baton:efficiency select …` |
| Health | `/baton:fleet doctor` |

## Octopus

Removed. Map old habits: [`docs/octo-to-baton-map.md`](octo-to-baton-map.md).
