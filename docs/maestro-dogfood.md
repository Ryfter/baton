# Maestro dogfood (Slice 1)

Queue work, fire, watch, hold. Jobs: `$BATON_HOME/maestro/jobs/mj-*.json` (default `~/.baton/maestro/jobs/`). Events: `events.jsonl` beside them. Spec: [`2026-08-15-maestro-front-door-design.md`](superpowers/specs/2026-08-15-maestro-front-door-design.md).

## Fire a job

Write `status: admitted` (oldest `created_at` wins):

```json
{
  "id": "mj-<12hex>",
  "project": "canvas-toolchain",
  "goal": "Ship install one-liner; read README + TO-WORK-ON/",
  "stakes": "standard",
  "missed_fire": "catch-up",
  "source": "cli",
  "status": "admitted",
  "run_id": null,
  "created_at": "2026-08-21T08:00:00Z"
}
```

Fire once from repo root:

```bash
[[ -f ~/.baton/overnight/.openrouter.env ]] && source ~/.baton/overnight/.openrouter.env
pwsh -NoProfile -File scripts/maestro-fire.ps1
```

`maestro-fire.ps1`: `admitted` → `running` → `fleet-go.ps1 -Execute -NoPlanGate -NoVerify` → patch `run_id`, `provider`, `done` or `waiting-quota`.

## Watch

```bash
~/.baton/overnight/bin/maestro-watch.sh          # 20s loop; stops on ~/.baton/overnight/STOP
~/.baton/overnight/bin/maestro-watch.sh --once
```

Log: `~/.baton/overnight/lanes/maestro-watch.log`. Point `FIRE` at **`/Users/kev/Dev/Baton/scripts/maestro-fire.ps1`** (main clone). Board: `~/.baton/overnight/swarm/out/MAESTRO-BOARD.md` · order: `~/.baton/overnight/MAESTRO-PARALLEL.md`.

## Hold

Slice 1 = manual patch (`POST /maestro/jobs/<id>/hold` planned):

```bash
jq '.status = "held"' ~/.baton/maestro/jobs/mj-XXXXXXXXXXXX.json \
  | sponge ~/.baton/maestro/jobs/mj-XXXXXXXXXXXX.json
jq '.status = "admitted"' ~/.baton/maestro/jobs/mj-XXXXXXXXXXXX.json \
  | sponge ~/.baton/maestro/jobs/mj-XXXXXXXXXXXX.json   # release
```

`maestro-fire` only picks `admitted`.

## Quick checks

```bash
ls ~/.baton/maestro/jobs/mj-*.json; tail -5 ~/.baton/maestro/jobs/events.jsonl; tail -3 ~/.baton/overnight/lanes/maestro-watch.log
```
