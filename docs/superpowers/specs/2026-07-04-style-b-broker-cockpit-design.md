# Style-B broker + cockpit (design)

**Date:** 2026-07-04
**Status:** DRAFT — batch-authored at Kevin's direction; defaults chosen,
forks flagged. Not yet approved. This is an EPIC (3 slices), the largest
item in the batch; it also realizes the parked 2026-06-10 Fleet Conductor
design spurt (async-broker operating model, web-first cockpit).
**Target:** v2.0 line candidate

## Problem

The Conductor's substrate is Style-A (d051): `/baton:go` runs inside a
Claude session, so a run occupies the session and dies with it. d051
deliberately left a **file-based seam** — every run communicates through
box-private artifacts (`plan.json`, `events.jsonl`, `decisions.jsonl`,
`report.md`, + gate/cost/shadow files) — so a standalone broker could swap
in without touching the engine. The payoff: submit a goal from a web
cockpit, close the laptop lid on the session, watch runs stream, and answer
the two structural interrupts (budget cap, destructive task) from a browser
— the autonomy north star's operating model.

## Decisions made (defaults)

- **Broker = a PowerShell watcher process, not a port.** A long-lived
  `scripts/baton-broker.ps1` loop that dot-sources conductor-lib and
  executes runs directly (same code path as fleet-go, zero engine changes).
  (Alternatives: a Python broker re-implementing dispatch — drift, rejected;
  spawning `pwsh fleet-go.ps1` children per run — acceptable fallback, but
  in-process reuse gives the broker live event hooks for free.)
- **Queue protocol = files under `$BATON_HOME/broker/`** (the d051 seam
  extended, everything box-private):
  - `queue/<id>.json` — submitted goal `{goal, budget_cap, gate_artifact,
    flags, submitted_at}`; broker claims by atomic rename to
    `active/<id>.json`, writes `runs/go-<ts>/` as today.
  - `interrupts/<run>-<n>.json` — a structural interrupt the engine would
    have asked the session: `{kind: budget|destructive, question, context}`.
    Broker parks the run (the DAG walk already stops at guard-before-spawn;
    the broker persists the resumable state) and polls for
    `answers/<run>-<n>.json` `{decision, by, at}`.
  - `broker.lock` + heartbeat file — single-instance guard; a stale
    heartbeat (>60 s) is reclaimable.
- **Cockpit rides the existing FastAPI dashboard** (`controls` router
  grows): submit form → writes `queue/*.json`; run watch = the Live Fleet
  Ops run strip + an interrupt inbox panel; answering an interrupt writes
  the answer file. The dashboard never executes anything — it only reads
  state and writes queue/answer files; the broker is the sole executor.
  (Alternative — a new cockpit app per the stitch 3-pane concept — the
  stitch IA informs the pages, but one server, one test suite.)
- **Interrupt semantics unchanged (d-cg-2):** still exactly two structural
  interrupt kinds. The broker adds *where* they're answered, never *how
  many* there are. Unanswered interrupts park forever (visible in the
  cockpit + coach digest) — no timeout-auto-answer.
- **Style-A stays.** `/baton:go` in-session remains the default; the broker
  is additive (`/baton:go --queue` or cockpit submit). The "not so smart
  but never blocked" conductor tier keeps working with zero broker running.

## Architecture

```
scripts/broker-lib.ps1      ← queue claim/heartbeat/interrupt/answer protocol (pure + seamed)
scripts/baton-broker.ps1    ← the watcher loop (CLI: start|status|stop)
scripts/conductor-lib.ps1   ← interrupt seam: guard hits call an injectable
                              -InterruptHandler (session handler = today's
                              behavior; broker handler = park + poll)
scripts/fleet-go.ps1        ← --queue (write a queue file and return)
dashboard/routers/controls  ← submit + interrupt-answer endpoints
dashboard/templates/…       ← submit form, interrupt inbox
commands/go.md, broker.md   ← docs; /baton:broker command surface
```

### Slices

1. **Broker daemon + queue protocol:** broker-lib + baton-broker + the
   `-InterruptHandler` seam + `--queue`. Prove: queue a run, broker
   executes headless, artifacts identical to Style-A, interrupts park and
   resume via hand-written answer files. CLI-only — no UI yet.
2. **Cockpit submit/watch:** dashboard submit form + run watch + broker
   status panel (depends on the dashboard Live Fleet Ops slice).
3. **Interrupt round-trip in the cockpit:** inbox + answer UI + coach rule
   ("a run is waiting on you → open the cockpit").

## Error handling

- Broker crash mid-run: heartbeat goes stale; `active/` file + run events
  show last state; restart re-queues unclaimed work but NEVER auto-resumes
  a run that had begun spawning (destructive-safety: a half-executed DAG
  needs human eyes; surfaced in cockpit as `orphaned`).
- Atomic rename is the claim primitive (no partial-read races); all writes
  utf8NoBOM; answer files validated against the interrupt's expected shape
  (malformed answer → ignored + logged, keeps polling).
- The broker never throws to its loop: per-run try/catch → run `failed`
  + event, loop continues.

## Testing

- broker-lib pure fns hermetic (temp BATON_HOME): claim/rename semantics,
  stale-heartbeat reclaim, interrupt round-trip, malformed-answer rejection.
- End-to-end: broker run with `BATON_GO_TEST_PLAN`/`BATON_GO_TEST_SPAWN`
  stubs — headless artifacts byte-compatible with a Style-A run.
- Dashboard endpoints with a fake broker dir (pytest).
- Session-handler regression: no `-InterruptHandler` → conductor suites
  byte-for-byte green.

## Open forks (for Kevin)

1. **Broker lifetime management:** manual `baton-broker start` in a
   terminal (default) vs a Windows scheduled task/service. Default manual
   until the pattern proves out.
2. **In-process runs vs `pwsh fleet-go.ps1` children:** default in-process;
   children give crash isolation at the cost of event-hook plumbing.
3. **Scope check:** this could be v2.0's headline. If it feels too big,
   slice 1 alone is independently valuable (headless queued runs, no UI).

## Non-goals

- No multi-box brokering, no network protocol (files on one box).
- No new interrupt kinds; no auto-answering.
- No replacement of Style-A; no session-Claude orchestration changes.
- Not the 3-pane pixel cockpit — the stitch IA informs, doesn't bind.
