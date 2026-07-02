---
description: Evolve the Conductor planner prompt (GEPA candidate pool, propose-then-apply)
argument-hint: "[--max-runs N] [--max-tier local|free|paid] [--reflect-tier T] [--generations N] [--pool] [--apply]"
---

Run the GEPA prompt-evolution loop over the Conductor's planner prompt.

Parse `$ARGUMENTS` for the optional flags, then run ONE PowerShell command
(keep it under 965 bytes):

- Default / evolve: `pwsh -NoProfile -File ~/.claude/scripts/fleet-optimize-prompt.ps1 [-MaxRuns N] [-MaxCostTier T] [-ReflectTier T] [-Generations N]`
- `--pool`: `pwsh -NoProfile -File ~/.claude/scripts/fleet-optimize-prompt.ps1 -Pool`
- `--apply`: append `-Apply` to the evolve form.

What it does:

1. Loads (or seeds, from the live prompt) the box-private candidate pool at
   `$BATON_HOME/prompts/pool/`.
2. Per generation: picks a parent from the Pareto front, a cheap reflection
   model diagnoses recent `polish`/`reject`-gated runs, a stronger mutation
   model rewrites the prompt, and the child is judged head-to-head
   (plan-only, position-swapped) against the champion over those runs.
3. Dual gate: the child must BEAT its parent on the minibatch AND be
   Pareto-non-dominated (judge win-rate vs prompt tokens). Placeholder loss
   or a blown length cap retires the child before any evaluation is spent.
4. Survivors are PROPOSED (`conductor-planner.candidate.txt`); the live
   prompt is only ever touched by `--apply`, which backs it up and promotes
   the survivor to champion in the pool.

Report the per-generation lines and the proposal/apply outcome to the user
in plain language. If the run exits 2, relay the reason honestly — "no
candidate survived the dual gate" is a normal, healthy outcome, not an error
to retry.
