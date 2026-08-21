# Buzz control-plane client — Mac mini remote for Baton factory

**Date:** 2026-08-21  
**Status:** design only — not authorized to build until an implementation plan exists  
**Decisions:** `baton-d111`, `baton-d108`, `baton-d109`  
**Companions:** `2026-08-15-maestro-front-door-design.md`, `maestro-fire.ps1`  
**Does not reopen:** deterministic Maestro; no LLM Maestro; no Fable.

Kevin fires the factory from a phone while the Mac mini runs the stack. Buzz is on the mini but has no path from mention → job record → fire.

One Buzz **member on the Mac mini** is a **remote control-plane client** — not the factory, not chat Maestro. It writes job JSON and reads status. Admission, quota, scheduling, and `baton go --execute` stay on the factory host.

No Buzz-acp at Claude/Codex (`baton-d111`). No schedule/claim/budget on phone. No second factory host. No Fable in Buzz.

## Architecture

```
Phone → Buzz member "Baton" (Mac mini, thin client)
           POST /maestro/jobs { source: "buzz", ... }
           GET  /maestro/jobs, /maestro/budget
        → Maestro inbox ($BATON_HOME/maestro/jobs/*.json)
        → maestro-fire.ps1 → fleet-go --execute
        → Conductor → Orchestrator → Instruments
```

Buzz never calls `fleet-go` or patches `running`/`done`. That is `maestro-fire` + the engine.

---

## Job write path

New work = one `POST /maestro/jobs` (front-door schema):

| Field | Buzz |
|---|---|
| `project` | Thread-bound slug; no project → clarify, no POST |
| `goal` | Mention text |
| `stakes` | Default `standard` |
| `source` | Always `"buzz"` |

Follow-ups on same thread/job → Conductor talk (job id), not duplicate POSTs unless project changes.

Replies: job id, status, provider/`run_id`, budget one-liners — deterministic only. Conductor chat via run artifacts.

## Pairing with maestro-fire

| Step | Owner |
|---|---|
| Write `mj-*.json`, `queued` → `admitted` | Maestro admission (deterministic) |
| Oldest `admitted` → `running` → `fleet-go` | `maestro-fire.ps1` |
| Patch `run_id`, `provider`, status, `events.jsonl` | `maestro-fire.ps1` + `maestro-lib.ps1` |
| Wake on new job + periodic tick | `launchd` on mini (`baton-d109`) |

Buzz writes; fire consumes. Buzz death does not stop the inbox.

---

## Success

From a phone Buzz thread: name project, paste goal, see `source: buzz` job record, factory ships via `maestro-fire` without Claude Code — including when Claude quota is empty.

Not done: pretty Buzz UI, multi-host durability.

One member on mini; app label may say “Maestro” — product is **Baton**. HTTP + thread state, not ACP with tools.
