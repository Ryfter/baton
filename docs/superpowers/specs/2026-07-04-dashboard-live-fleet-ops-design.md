# Dashboard integration — Live Fleet Ops + Model Leaderboard (design)

**Date:** 2026-07-04
**Status:** DRAFT — batch-authored at Kevin's direction ("Create specs for 2–8");
defaults chosen, genuine forks flagged in "Open forks" below. Not yet approved.
**Target:** v1.9 line (each slice its own RC)

## Problem

Baton's telemetry is rich but terminal-only: run artifacts (`plan.json`,
`events.jsonl`, `acceptance.json`, `effective-cost.json`, `shadow.json`),
the usage governor's worker states, the prompt-pool live A/B, and the
per-worker effective-cost leaderboard all exist as box-private files read by
CLIs. Kevin's "Obsidian Command" cockpit concepts (three Google-stitch
exports under `dashboard/Design from Google stitch/` — **Live Fleet Ops**
is the preferred nav; **Analytics/System Intelligence** hosts a MODEL
LEADERBOARD) are parked, waiting for integration into the existing FastAPI
dashboard (`dashboard/` — readers, routers, Jinja2 templates, 124-test
suite). The legibility north star says this state should be *glanceable*.

## Decisions made (defaults — Kevin may redirect)

- **Extend the existing FastAPI dashboard, not a new app.** The app already
  has `baton_home()` path resolution, env-overridable roots, readers,
  routers, and a green test suite. (Alternative — stand up the stitch HTML
  as a separate static site — rejected: no data plumbing, second server.)
- **Stitch exports are visual reference, not code.** Implement as Jinja2
  templates + project CSS matching the Obsidian Command look. The stitch
  zips/HTML stay untouched as design artifacts. Kevin's uncommitted
  `dashboard/static/style.css` WIP is preserved and extended, never
  clobbered.
- **Data comes from the PS CLI `--json` surfaces via subprocess, not
  Python re-implementations of the folds.** `fleet-usage.ps1 status --json`,
  `fleet-effective-cost.ps1 --json`, `fleet-optimize-prompt.ps1 --pool`
  (JSON mode) are the single sources of truth for fold semantics
  (usage-journal fold, leaderboard confidence gating, shadow verdict).
  Re-implementing those folds in Python is guaranteed drift. Mitigation for
  pwsh startup latency: a small TTL cache (default 15 s) per CLI call in a
  new `dashboard/readers/pscli.py`. Run *artifacts* (plain JSON files under
  `$BATON_HOME/runs/go-*/`) are read directly in Python — they are data,
  not folds.
- **Read-only.** No mutating controls in these slices (the existing
  `controls` router keeps whatever it has; no new writes). Cockpit-style
  controls belong to the Style-B broker spec.
- **Localhost, no auth** — unchanged from the current dashboard posture.
  Box-private data never leaves the box.

## Architecture

```
dashboard/readers/pscli.py      ← NEW: run a PS CLI with --json, TTL cache
dashboard/readers/fleet_runs.py ← NEW: scan $BATON_HOME/runs/go-*/ artifacts
dashboard/routers/fleet.py      ← NEW: /fleet (Live Fleet Ops), /fleet/leaderboard
dashboard/templates/fleet_ops.html, leaderboard.html + partials
dashboard/static/…              ← Obsidian Command styling (extends Kevin's WIP)
```

### Slice 1 — Live Fleet Ops pane

One page answering "what is the fleet doing and can it take work":

- **Worker board:** every fleet.yaml worker with governor state
  (`available|limited|exhausted|cooling_down|waiting_for_reset`), conserve
  banner, budget/utilization/forecast where present — from
  `fleet-usage status --json`.
- **Recent runs strip:** last N `go-*` runs — status, goal (from
  `plan.json`), verdict badge (from `acceptance.json`), realized cost +
  effective cost (from `effective-cost.json`), shadow variant tag (from
  `shadow.json`). Click-through to a run detail page rendering `report.md`
  and the events/decisions ledgers.
- **Pool one-liner:** champion/challenger + verdict state from the pool
  JSON surface (same line the coach digest prints).

### Slice 2 — Model Leaderboard (System Intelligence)

The `Get-WorkerEffectiveCost` board rendered: per-worker eff_cost mean,
confidence, run count, rank — from `fleet-effective-cost --json` — plus,
when `learned_routing` is on, the live `learned_adjust`/`why` per candidate
so routing behavior is explainable at a glance.

## Error handling

- A failing/timing-out pwsh subprocess degrades that panel to "unavailable"
  with the stderr snippet — never a 500 for the whole page (per-panel
  fail-open, same philosophy as the coach's context readers).
- Absent `$BATON_HOME`, absent runs dir, malformed artifact JSON → empty
  panels with honest "no data yet" copy.
- Subprocess calls use fixed argument lists (no string interpolation of
  user input into the command line; 965-byte rule respected trivially).

## Testing

Extends the existing pytest suite (must stay green):

- `pscli.py`: cache TTL honored; subprocess failure → typed error result,
  not an exception; JSON parse failure → error result.
- `fleet_runs.py`: fixture runs dir (complete run, gate-less run, corrupt
  `effective-cost.json`) → correct strip rows, corrupt file skipped.
- Router tests with `pscli` monkeypatched (no real pwsh in CI): page 200s,
  panels render, per-panel degradation renders.

## Slicing and release

- **Slice 1:** pscli reader + fleet_runs reader + Live Fleet Ops page.
- **Slice 2:** leaderboard page + learned-routing explainability.
- Each slice: own branch/PR, opus final review, plugin RC bump.

## Open forks (for Kevin)

1. **Subprocess-vs-port:** if pwsh-per-request latency annoys even with the
   TTL cache, the fallback is porting the folds to Python (drift risk) or a
   long-lived pwsh sidecar. Default: subprocess + cache.
2. **How much stitch fidelity:** pixel-faithful Obsidian Command vs "same
   information architecture, simpler styling." Default: information
   architecture first, styling iterated with Kevin's CSS WIP.

## Non-goals

- No auth/multi-user, no reverse-proxy hardening (localhost only).
- No mutating controls (submit goal / answer interrupts = Style-B cockpit).
- No websockets/live-push in these slices — meta-refresh/htmx polling only.
- No third stitch concept (Token Cost & Analytics) yet.
