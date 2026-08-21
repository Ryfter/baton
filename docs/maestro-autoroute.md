# Maestro auto-route contract

**Under test:** full Baton architecture (Maestro → Conductor → Orchestrator → Instrument).

## Kevin’s job (only)

Say **which project** and **what to do**.

Examples:

- “In canvas-toolchain, simplify install.”
- “AtomicForge — finish MCP smoke.”
- “Make the tower defense bosses cooler.”

## Maestro’s job (always)

1. **`ensure-conductors.sh`** — every `~/.baton/projects/*` has a running Conductor job.
2. **Resolve** the project id from the utterance (folder name, alias, or explicit).
3. **Update** that Conductor’s maestro job goal with the new task (or admit a child job).
4. **Mouth** (Ox) brief if useful — non-blocking.
5. **Fan ≥2 Orchestrators** with disjoint file claims on that project; keep other Conductors warm with background instruments when capacity allows.
6. **Never** ask Kevin to spawn a Conductor. Spawning is an internal failure if the human notices.

## Forbidden

- “Want me to spawn a conductor for X?”
- Finishing project A before touching B when both were implied
- Pausing Baton while other projects run
- Making Kevin manage the org chart

## Registry

Projects live in `~/.baton/projects/<id>/project.json`. Missing id → register from `/Users/kev/Dev/<Folder>` then ensure.

## Dogfood Conductor

`baton-architecture` (`mj-*`) owns improving this contract until Kevin only ever names project + task.
