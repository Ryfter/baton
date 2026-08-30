# Maestro Home redesign — shift board + project economics

**Date:** 2026-08-23
**Status:** approved — shipped (Home + Gauges + parked backlog on `WT-front-door`)
**Audience:** dashboard implementer on `WT-front-door` (claim: `dashboard/` only)
**Companions:** `2026-08-15-maestro-front-door-design.md`, `2026-08-23-gauges-page-design.md`
**Visual review:** Antigravity + Gemini 3.7 Flash High (`scratch/antigravity-dashboard-research.txt`, 2026-08-23)
**Operator URL:** `http://droid:8765/` (PC overnight watch)

---

## Problem

Home today is a junk drawer: admit + factory floor + fleet + runs + jobs + KB + spend doughnut + leaderboard + activity feed on one scroll (`dashboard/templates/index.html`). Kevin cannot answer in three seconds:

1. **What needs me right now?**
2. **What is each project doing?**
3. **Which models/providers are burning tokens, at what API-equivalent cost, and how much did routing save?**

Portfolio, Machines, and Gauges were split out, but Home still pretends to be all of them. The brass/dark **theme is good** — the **story architecture** is wrong.

## Goal

One **shift board** on `/` that tells past / present / future on the same objects:

| Beat | Question | Where on Home |
|---|---|---|
| **Future** | Can the night keep firing? | Thin capacity strip → `/gauges` |
| **Present** | Who needs me? What is moving? | Attention rail + project cards (port) |
| **Past** | What already happened tonight? | Project card visual report (tokens, $, savings) |

Kevin chose **layout B**: admit + attention + floor, with a thin capacity strip (no charts on Home). Savings counterfactual is **C — per-provider policy** (Ox-Alpha $0 while free; switch to OpenRouter rates after cap).

Success: open Home at 3am, spot **NEEDS YOU** in one glance, admit a job without scrolling, see each active project as one card with live port + model/provider economics, and know whether Ox-Alpha is doing the heavy lifting while free.

## Non-goals (this spec)

- Replacing the dark/brass theme. **Keep current palette.**
- Theme picker / appearance settings (parked — bottom of backlog).
- Re-adding Portfolio dump, Controls dump, or BI widgets to Home.
- Live HTTP probes from Home (read files the factory already writes).
- Full Cogpit timeline in every floor cell (microscope only for featured/port).
- Editing `scripts/` or fleet admit logic (dashboard reads fleet + journal; does not change routing).
- Bubble graphs, doughnuts, or leaderboard on first paint.
- Durability / multi-host Maestro (unchanged from 2026-08-15 spec).

---

## Decisions

| Choice | Locked | Rejected |
|---|---|---|
| Home layout | **B** — attention + capacity strip + admit + project cards | Floor-first with admit hidden; analytics on Home |
| Visual theme | **Keep current dark + brass** | Redesign palette before story works |
| First find | **NEEDS YOU rail** above everything except maybe capacity | Attention buried in floor sort |
| Admit | **Near top** (below needs-you + capacity strip) | Admit at bottom or separate page |
| Unit of story | **One card per project** with port + visual report | Registry grid + separate runs/jobs panels |
| Model economics | **Provider → model** two-level breakdown | Model-only (loses Cursor/OR instrument) |
| Savings baseline | **C — per-provider policy** | A (all Sonnet); B (each line’s list price only) |
| Deep quota / caps | **`/gauges`** | Cap gauges duplicated on Home |
| Machine catalog | **`/machines`** | LM Studio dump on Home |
| Theme setting | **Later** | Build now |

---

## Layout — Home (`/`)

```
┌─ NEEDS YOU ─────────────────────────────────────────────┐
│ 2 waiting-quota · 1 held · AnswerBot needs permission   │  ← impossible to miss
└─────────────────────────────────────────────────────────┘

┌─ CAPACITY (thin strip, links to /gauges) ───────────────┐
│ Claude 5h empty · 47m  ·  1.2M tok this window  ·  →   │
└─────────────────────────────────────────────────────────┘

┌─ ADMIT ──────────────────────────────────────────────────┐
│ [project chips]  goal…  [Admit]                          │
└─────────────────────────────────────────────────────────┘

┌─ PROJECT CARD — AnswerBot ──────────────────────────────┐
│ NEEDS YOU · running · ox-alpha                            │
│ goal one-liner…                                           │
│ last output one line… · 2m ago                            │
│ ┌─ PORT (collapsed default; expand = microscope) ─────┐ │
│ │ step · last turn output · [expand full port]         │ │
│ └─────────────────────────────────────────────────────┘ │
│ ┌─ THIS WINDOW (always visible) ──────────────────────┐ │
│ │ openrouter / ox-alpha   280k tok  $0.00  ████████   │ │
│ │ grok-cli / grok-3       120k tok  $0.40  ███░░░░░   │ │
│ │ Saved $18.40 vs policy-priced API                     │ │
│ └─────────────────────────────────────────────────────┘ │
│ [Open port]  [Open in front door]                         │
└─────────────────────────────────────────────────────────┘
… one card per project with labor in the current window OR active job …
```

**Reading order:** needs-you → capacity → admit → cards sorted by attention (needs-human → waiting-quota → running → admitted → idle).

**Remove from Home** (move, merge, or delete):

| Current block | Action |
|---|---|
| Fleet activity + assignments | Move to `/machines` or drop |
| Runs gutter + run detail | Merge into project port |
| Jobs list partial | Merge into cards (job id on card) |
| KB search | Portfolio or global palette later |
| Spend today, doughnut, leaderboard, activity feed | **Gone from Home** — window economics live on cards; fleet-wide on `/gauges` |

Nav unchanged: Home · Portfolio · Machines · Gauges.

---

## Attention rail

**Purpose:** “HEY THIS NEEDS YOU” in &lt;1 second.

**Include (any match → row in rail):**

- Maestro job `waiting-quota`, `held`
- Permission / user-input states when detectable (future: pane-truth hook; v1: status + events.jsonl kinds)
- Projects with no progress beyond threshold (future: loop detector; v1: optional)

**Empty state:** one quiet line — “Floor is clean — nothing needs you.”

**Visual:** distinct from brass cards — amber/red band, text-first, no chart. Click row → scroll/focus that project card or open port.

**Mobile / Buzz:** rail alone should be enough for a phone check at 3am.

---

## Capacity strip

**Purpose:** future beat without Home charts.

One line, monospace, links to `/gauges`:

- Claude 5h label when snapshot exists (`empty · resets in 47m`), else omit
- Window token total (same 5h clock as Gauges)
- Optional: “next fire” when jobs are queued/admitted

Never show stub strings (`empty-until-reset`, fake usable chips). Hide missing fields.

---

## Project card

One card per **project with active labor** (running/queued job OR token spend in current 5h window). Idle registry projects stay off Home.

### Header

- Display name (registry)
- Attention pill: `needs you` | `waiting-quota` | `held` | `running` | `admitted` | `idle`
- Primary instrument if known (`j.provider` or dominant model route)

### Labor rows

- Goal (one line, truncate)
- Last output (one line) + recency
- Job id / run id as `code`, not hero

### Port (microscope)

- **Default:** collapsed — current step + one-line last output
- **Expanded:** turn timeline for **this project’s active job only** — output visible; thinking/commands in collapsed `<details>` (same rule as current cockpit partial)
- **Open port** = expand in place or anchor to featured status well (`#maestro-status`) without navigating away

Do **not** render six open turn dumps on every card in the grid.

### Visual report (always visible, compact)

Two-level table inside the card:

| Level 1 | Level 2 | Tokens | Actual $ | Share bar | Tier |
|---|---|---|---|---|---|
| Provider / instrument | Model name | in+out | journal sum | % of project window | free / local / paid |

- **Provider** = fleet provider name when known (`openrouter-glm`, `codex`, `cursor-agent`, …)
- **Model** = OTel `model` field
- **Actual $** = sum of `cost_usd` on matching lines in the **current 5h window** (same clock as Gauges)
- **Tier** = fleet `cost_tier` + policy state at line time (see Savings)

Sort rows by tokens desc. Ox-Alpha while free should visually dominate when routing is healthy.

### Savings line (one sentence under table)

> **Saved $18.40** — routed free/cheap vs policy-priced API

Tooltip or `<details>` for breakdown by provider (optional v1.1).

### Actions

- **Open in front door** — existing `/?project=` + compose scroll (keep)
- **Open port** — expand microscope

### Goal display sanitizer (Antigravity amendment)

Server-side filter on card goal/title before render:

1. Strip HTML comments (`<!-- ... -->`)
2. Strip leading date/author preambles (`Tonight 2026-08-23 —`, etc.)
3. Strip filesystem prefixes (`Repo: /Users/...`, `Worktree: ...`)
4. Truncate to ~90 characters for card subtitle

Raw goal stays in port/detail; card shows human intent only.

### Stall heartbeat (Antigravity amendment)

If job status is `running` but no new OTel line or Maestro event for **>300s**, badge becomes `STALLED (5m)` with amber border. Show `last_turn_seconds_ago` on running cards.

---

## Admit strip — collapsed default (Antigravity amendment)

`#maestro-compose-card` default height **≤56px** (single-line input + top project chips). On focus/paste, expand to multi-line (`min-height: 120px`). Ensures first project-card row is above the fold on 1080p.

Remove duplicate project `<select>` when chips cover the same field. Cap visible chips to ~5 recent + overflow.

---

## Economics panel — visual grammar (brass theme)

Nested panel inside each card:

```
┌─ WINDOW SPEND & ROUTING (Policy C) ─────────────────────┐
│ openrouter / ox-alpha   412k tok  $0.00  ████████ [FREE]│
│ grok-cli / grok-3        85k tok  $0.34  ██░░░░░░ [PAID]│
│ ✦ Saved $16.80 vs policy API (Ox-Alpha 74% of load)      │
└─────────────────────────────────────────────────────────┘
```

- Panel bg: `rgba(15, 19, 26, 0.6)`, border `rgba(212, 165, 116, 0.12)`
- Share bars: `--maestro-brass` (free), `--maestro-brass-dim` (local), muted blue/gray (paid metered)
- Savings callout: `--maestro-ticket` tint + `✦` glyph

---

## HTMX calm updates (Antigravity amendment)

`/partials/home-board` poll (~2s) must use DOM morphing (`hx-swap="morph:outerHTML"` or morphdom extension):

- Card order stable unless attention state changes
- Open port `<details>` and scroll position preserved under cursor
- Numbers tick in place; no layout jump

---

## Home eviction list (explicit)

Remove from `index.html`:

- `<canvas id="costChart">`, `chartLabels`, `chartData`, `app.js`
- `/partials/leaderboard`, `/partials/spend`, `/partials/activity` polls
- Fleet + assignments row, runs gutter, jobs list partial, KB search partial

Fleet BI → `/gauges` and `/portfolio` only.

---

## Savings — per-provider policy (choice C)

**Intent:** show allocation quality — “Ox-Alpha should carry the load while free.”

For each OTel line in the window:

1. **Resolve project** — `job:` → Maestro / Plan-3 manifest (same as Gauges).
2. **Resolve provider** — job `provider` if set; else infer from model via fleet map; else `unknown`.
3. **Resolve model** — line.model.
4. **actual** = line.cost_usd (already in journal).
5. **counterfactual** = what the same tokens would cost under **policy-aware** pricing at `line.timestamp`:

| Provider state | Counterfactual rule |
|---|---|
| `cost_tier: free` and within free cap/window (e.g. Ox-Alpha not capped) | Published API rate for that model (OpenRouter list or fleet reference table) |
| `cost_tier: free` but cap hit / window expired | OpenRouter (or provider) marginal rate — **no savings** vs actual |
| `cost_tier: local` | API equivalent for model class (reference table; local actual ≈ $0) |
| `cost_tier: paid` subscription (Claude, Codex) | Marginal API rate for that model (opportunity cost) |
| `cost_tier: paid` prepaid (OpenRouter credit) | Same model list price (savings ≈ 0 unless routed elsewhere cheaper) |
| Unknown | Omit from savings sum; show in table without savings contribution |

6. **line_savings** = max(0, counterfactual − actual)
7. **card_savings** = sum(line_savings) for project window
8. **headline** on card: round to cents, plain language

**Policy inputs (read-only):**

- `~/.baton/fleet.yaml` — provider `cost_tier`, `usage_policy`, model pins
- `~/.baton/usage-probe-cache.jsonl` / `claude-quota.json` — cap state when needed for “still free”
- Reference rates — v1: static JSON shipped with dashboard (`dashboard/data/api-rates.json`) keyed by model id; update manually until fleet exposes rates

**Never invent savings** when provider or rate unknown — show “—” not $0 saved.

---

## Data & architecture (dashboard only)

| Unit | Job |
|---|---|
| `readers/project_economics.py` (new) | Fold window OTel by project → provider → model; compute savings via policy C |
| `readers/cockpit_grid.py` (extend) | Project-centric cells: attention rank, port payload, economics embed |
| `readers/gauges.py` (existing) | Fleet-wide window clock — strip on Home imports same clock helper |
| `GET /` | Render new Home template (no doughnut script) |
| `GET /partials/home-board` | HTMX poll ~2s for rail + cards + strip |
| `GET /partials/project-port?project=` | Expanded port for one project |
| `GET /api/project-economics` | JSON for tests |

Reuse: `journal.py`, `maestro_jobs.py`, `claude_quota.py`, `gauges.resolve_window`, fleet parse from `machines.py`.

**Theme:** no CSS palette change in v1; reuse `--maestro-brass` tokens. New components: `.attention-rail`, `.capacity-strip`, `.project-card`, `.project-economics` — same factory voice.

---

## Error handling

- Missing journal → cards show “no token lines this window”; rail still works from Maestro jobs.
- Unknown provider/model → show tokens, hide savings contribution.
- Corrupt fleet → tier falls back to `unknown`; no fake free tier.
- HTMX poll must not reshuffle cards under cursor (calm updates — schmux rule).

---

## Testing

- Fixture journal: two projects, mixed providers/models, one Ox-Alpha line → savings &gt; 0 while free tier mocked.
- Cap hit fixture → Ox-Alpha savings drops to ~0 for lines after cap.
- Attention rail: waiting-quota + held jobs surface; clean floor → empty copy.
- Home HTML: no doughnut canvas, no `empty-until-reset`, needs-you rail present.
- Card sort: needs-human before running before idle.
- `/gauges` unchanged; capacity strip matches Gauges window totals.

---

## Parked (explicit backlog) — shipped 2026-08-28

- ~~Theme / appearance setting~~ — header theme picker (`brass` / `slate` / `ember`), persisted in localStorage
- ~~Loop detector + regression banner (Siddique pattern) on Gauges first~~ — `factory_health` + Gauges banner; Home already uses AgentTrail/AgentPulse observability
- ~~Global `Cmd+K` palette for KB/admit~~ — command palette in `base.html` + `/api/command-palette`
- ~~Pane-truth “needs permission” beyond Maestro status JSON~~ — `pane_truth.py` scans events + `$BATON_HOME/observability/pane-truth.json`

---

## Spec self-review

- Layout B, theme keep, attention + admit + cards locked.
- Savings C defined with per-provider cap behavior.
- Scope is dashboard Home + economics reader; no fleet script edits.
- Home removals explicit (doughnut, leaderboard, etc.).
- Port is collapsed-by-default to avoid Cogpit-in-every-cell failure mode.
- No TBD placeholders on core behavior.

---

## Approval gate

Kevin approved: **B**, **keep theme**, **C savings**, project cards with port + provider/model economics. **Next step after spec approval:** implementation plan (`writing-plans`), then build on `WT-front-door`.
