# Gauges page — live 5h burn + real cap instruments

**Date:** 2026-08-23
**Status:** design locked — not authorized to build until Kevin approves this spec and an implementation plan exists
**Audience:** dashboard implementer on `WT-front-door` (claim: `dashboard/` only)
**Surface:** `GET /gauges` — new top-nav tab beside Home / Portfolio / Machines
**Does not replace:** Home spend doughnut, model leaderboard, or Machines

---

## Problem

Home already shows after-the-fact totals (today’s $, all-time doughnut, leaderboard). The factory front door shows jobs and floor cards. Neither answers, in three seconds from the PC:

1. Which **projects** are burning tokens in the **current 5h window**, and is that pile still climbing?
2. How full are the **real** caps (Claude 5h / week, Codex, OpenRouter) — without a stub that looks like “5h to reset”?

Kevin watches overnight from the PC at `http://droid:8765/`. He wants factory instruments, not a finance dashboard.

## Goal

A dedicated **Gauges** page that is the overnight stare-at surface:

- **Top:** one needle per project that has spend in the current 5h window. The hero number is tokens. It ticks up as new journal lines land. $ and models are small print. A thin fill is that project’s share of the window’s token pile.
- **Bottom:** cap gauges only when a real snapshot exists. Missing = hidden.

Success: open `/gauges` from the PC, see project needles move within a couple of seconds of new OTel/journal lines, and see Claude remaining as minutes (e.g. `empty · resets in 47m`), never `empty-until-reset`.

## Non-goals (v1)

- Putting gauges on Home, or a Home “5h burn” chip (rejected; Home stays admit + factory floor).
- Tonight-vs-cap $ gauge (not selected).
- Live HTTP probes from the page (Claude API, OpenRouter, CodexBar). Those are credentialed/slow; the page only **reads files the factory already writes**.
- Editing `scripts/` or fleet admit. Dashboard claim only.
- Replacing Portfolio, Machines, or the Home analytics cards.
- Per-turn token streams from model APIs we do not already journal.
- Analog SVG manometers as a v1 requirement. Factory look = dark + brass cards, climbing numbers, honest fills. Fancy needles can wait.

## Decisions

| Choice | Locked | Rejected |
|---|---|---|
| Jobs on the page | Both: live project burn **and** window/cap gauges | Burn-only or caps-only |
| Hero split | **By project**; model is subtitle | By model, or equal project×model matrix |
| Needle clock | **Current 5h window** (same clock as Claude reset when known) | Local midnight / rolling hour as the hero clock |
| Caps on v1 | Claude 5h, Claude week, OpenRouter credit, Codex 5h/week | Tonight $ vs a hand-set cap |
| Missing data | **Hide the gauge** | Stub, “unknown”, or `empty-until-reset` |
| Placement | **`/gauges` nav tab** | Home hero, or tab + Home chip |
| Idle projects | Off the board (or dim only if they had spend this window and then went quiet) | Always show every registry project |

## Layout

```
[ Home ] [ Portfolio ] [ Machines ] [ Gauges ]

Gauges
  clock: 5h window 02:40 → 07:40  ·  1.2M tok  ·  $4.18   [fallback label if not Claude’s clock]

  ┌ AnswerBot          412k tok ███░░░░  $1.10 ─┐
  │ ox-alpha · grok                             │
  └─────────────────────────────────────────────┘
  ┌ Baton              280k tok ██░░░░░  $0.40 ─┐
  │ codex · ox-alpha                            │
  └─────────────────────────────────────────────┘

  Caps (omit any card with no snapshot)
  ┌ Claude 5h   100%  empty · resets in 47m ─┐
  ┌ Claude week  62%  resets in 4d 3h       ─┐
  ┌ Codex 5h     41%  resets in 2h 10m      ─┐
  ┌ OpenRouter   $12.40 left                ─┐
```

Copy voice: factory instruments. Labels people recognize (project name, Claude, Codex), not “OTel aggregation.”

## Data

### Project needles

**Source:** `model-routing-log.md` OTel lines already parsed by `dashboard/readers/journal.py` (`model`, `input_tokens`, `output_tokens`, `cost_usd`, optional `job_id` / `phase`).

**Project join:**

1. Journal `job:` tag → Maestro job JSON `project` when the id is `mj-*`.
2. Else Plan-3 jobs / run records if they already carry `project`.
3. Else a single **unassigned** needle so untagged spend does not vanish.

**Window:**

1. If `~/.baton/claude-quota.json` has a future `five_hour.resets_at`, the open window is `(reset − 5h, reset]`.
2. Else rolling last 5 hours, and the clock line must say **fallback — rolling 5h**, never “Claude’s window.”

**Per project card:** `tokens = in + out` (hero), `cost_usd`, `models` (names that spent in-window, hottest first), `share = tokens / window tokens`. Sort: live/highest tokens first.

**Climb:** poll the page (HTMX or existing WS style) every 2s. New journal lines raise the number. Do not animate fake increments.

### Cap gauges

Read-only snapshots. Do not invent.

| Gauge | File / field | Hide when |
|---|---|---|
| Claude 5h | `claude-quota.json` `five_hour` (statusline already writes this) | file missing or no `resets_at` / `used_pct` |
| Claude week | `claude-quota.json` `seven_day` | same |
| Codex 5h / week | `usage-probe-cache.jsonl` latest fresh Codex/five_hour + weekly row | no fresh row |
| OpenRouter credit | probe cache / usage-journal prepaid observation if already present | no remaining/limit fields |

Reuse `dashboard/readers/claude_quota.py` labels (`empty · resets in 47m`, `88% · resets in 18m`). Never `empty-until-reset`.

## Architecture (dashboard only)

| Unit | Does | Depends on |
|---|---|---|
| `readers/gauges.py` | Fold journal + joins + window + cap snapshots into one JSON payload | `journal.py`, `claude_quota.py`, maestro job JSON, optional probe cache |
| `GET /gauges` | Full page | `base.html` nav |
| `GET /partials/gauges` | HTMX inner swap every 2s | same reader |
| `GET /api/gauges` | JSON for tests / later WS | same reader |
| `templates/gauges.html` + `partials/gauges_board.html` | Two-band layout | existing `style.css` brass tokens |
| `tests/test_gauges.py` | Window fold, project join, unassigned, hide-missing caps, no stub string | tmp fixtures only |

No new JS chart library required for v1. Chart.js is already vendored if a spark is cheap; default is CSS fill + number.

`base.html` nav: Home · Portfolio · Machines · **Gauges**.

## Error handling

- Missing journal → empty needles, clock still shown, muted “no token lines in this window.”
- Corrupt snapshot JSON → skip that gauge, do not fail the page.
- Probe cache stale (TTL expired if the row has `ttl` / `observed_at`) → hide that cap.
- Timezones: all window math in aware UTC; display local (America/Boise on this factory).

## Testing

- Fixture journal with two projects + one untagged OTel line inside a known 5h window; assert two project needles + unassigned, token sums, sort.
- Line just outside the window excluded.
- `claude-quota.json` present → clock is Claude’s window; absent → fallback label.
- Caps: only Claude 5h fixture → one cap card; assert `empty-until-reset` never appears in HTML.
- `/gauges` returns 200 with the nav tab active.

## Out of v1 (parked)

- Analog needle SVGs, sparkline history, per-model matrix, WebSocket push (poll is enough), writing new probe scripts, Home chip.

---

## Spec self-review

- No TBD/TODO placeholders.
- Layout and data sections match the locked choices (project hero, 5h clock, hide-missing, dedicated tab).
- Scope is one dashboard page + reader + tests; no fleet/script work.
- “Tokens” means in+out for the hero number (explicit).
- Unassigned needle is explicit, not optional.
