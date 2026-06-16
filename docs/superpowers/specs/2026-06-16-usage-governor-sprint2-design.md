# Usage Governor — Sprint 2 Design

**Status:** approved (design) — 2026-06-16
**Sprint:** 2 of the Baton v2 economic-conductor MVP (Sprint 1 = Triage Agent, shipped)
**Goal:** Give Baton a worker-availability state machine so it stops spending calls on
workers it knows are rate-limited, tracks reset ETAs, exposes a global conserve posture,
and offers a best-effort usage forecast — the "spend intelligence like money" north star.

> **Economic-conductor framing:** the Usage Governor is the v2 subsystem seeded by v1's
> `usage_class` field. It owns *worker availability and budget awareness*; it does NOT
> execute work, meter tokens for billing, or measure model quality (that's the routing
> learning loop). See `project_baton_v2_direction` and the v2 architecture brief.

---

## 1. Scope

**In scope (Sprint 2 MVP):**

- An append-only usage event log under BATON_HOME.
- Five per-worker availability states derived by folding the log, with time-based auto-expiry.
- A global `conserve_mode` posture.
- Manual lockout / limit / cooldown / clear commands with optional reset ETAs.
- Route-around-exhausted: a usage filter inside `Select-Capability`.
- A deliberately simple, best-effort 7-day forecast that is honest about sparse data.
- A `/baton:usage` slash command + `fleet-usage.ps1` CLI runner.
- Bootstrap deployment + tests.

**Explicitly out of scope (later slices):**

- Auto-detecting rate-limit / quota errors from dispatch failures (Sprint 2.5). MVP lockout
  is **manual**, matching the v2 brief.
- Token-accurate billing/metering pipelines. The forecast counts whatever `tick` events
  exist; it does not instrument every dispatch.
- Per-project budgets. Budgets are per-worker, box-private, and global to the box.
- Predictive smoothing / ML forecasting. The forecast is linear run-rate only.

---

## 2. Decisions made

- **d-usage-1 — Event-sourced state, not a mutable state file.** Current state is *derived*
  by folding an append-only `usage-journal.jsonl`. Alternatives: a single mutable
  `usage-state.json` (simpler reads, but loses the history the forecast needs and fights the
  established `Read-JsonlRows` pattern). Chosen because history is required for the forecast,
  the append-never-crash JSONL pattern is already proven (`routing-journal.jsonl`,
  `routing-ratings.jsonl`), and event-sourcing matches the Projectmem-style memory direction.
- **d-usage-2 — Best-effort forecast off the event log.** The forecast folds whatever `tick`
  events exist into a linear daily run-rate and reports `insufficient_data` honestly when
  sparse. Alternatives: meter every dispatch (more accurate, but couples the Governor to the
  dispatch path and balloons the sprint) or defer the forecast entirely (under-delivers vs the
  brief). Chosen to deliver a real forecast at minimum scope. (User-selected, 2026-06-16.)
- **d-usage-3 — Route-around is a `Select-Capability` filter.** Exhaustion is enforced at the
  single routing chokepoint every dispatch path funnels through, as one more filter step
  alongside the existing cost-tier and context-floor filters. Alternative: filter in each
  caller (`routing-cascade`, `routing-dispatch`, `mcp-bridge`) — rejected as duplicative and
  drift-prone.
- **d-usage-4 — State lives in BATON_HOME, never the knowledge repo.** Worker usage, reset
  ETAs and budgets are box-private operational data (my workers, my limits). They stay local
  in `~/.baton`, never the GitHub-backed knowledge repo, and never appear in shareable seed
  artifacts with real values. (Honors the box-private standing order.)
- **d-usage-5 — `conserve_mode` is a global posture, not a sixth worker state.** It is a single
  on/off lever that biases routing cheaper. Modelled as a `worker:"*"` event so it folds out of
  the same log.
- **d-usage-6 — Two-axis "stop" semantics: hard vs soft.** `exhausted` / `cooling_down` /
  `waiting_for_reset` are **hard** (excluded from selection); `limited` is **soft**
  (down-ranked, still selectable) — until `conserve_mode` is on, when `limited` becomes hard too.

---

## 3. Data model — `usage-journal.jsonl`

One JSON object per line, appended under `Get-BatonHome`/`usage-journal.jsonl`. Every row has
`ts` (ISO-8601) and `event`. Reader: a thin wrapper over the existing `Read-JsonlRows` contract
(missing path → empty; malformed lines skipped; callers wrap in `@()`).

| `event` | fields | meaning |
|---|---|---|
| `lockout` | `worker`, `reset_at?`, `reason?` | hit the wall. `reset_at` present → `waiting_for_reset`; absent → `exhausted` |
| `cooldown` | `worker`, `until` | short transient backoff; auto-expires at `until` |
| `limited` | `worker`, `reset_at?`, `reason?` | soft cap — selectable but down-ranked |
| `clear` | `worker` | manual return to `available`; supersedes prior state events |
| `tick` | `worker`, `count`, `unit?` | usage observation feeding the forecast (`unit` default `requests`) |
| `conserve` | `worker:"*"`, `on` (bool) | global posture toggle |

Example rows:

```json
{"ts":"2026-06-16T09:00:00Z","event":"lockout","worker":"claude-sonnet","reset_at":"2026-06-16T14:00:00Z","reason":"weekly cap hit"}
{"ts":"2026-06-16T09:05:00Z","event":"tick","worker":"claude-haiku","count":12,"unit":"requests"}
{"ts":"2026-06-16T09:10:00Z","event":"conserve","worker":"*","on":true}
```

---

## 4. State machine

`Get-WorkerState -Worker <name> [-Now <DateTime>] [-UsagePath <path>]` returns
`{worker, state, reset_at, eta_human, reason}`. Fold rule, per worker:

1. Take the latest state-setting event (`lockout` / `cooldown` / `limited` / `clear`) by `ts`.
2. Apply time-expiry against `Now` (default `[DateTime]::UtcNow`):
   - `lockout` with `reset_at` and `Now >= reset_at` → `available` (expired).
   - `lockout` with `reset_at` and `Now < reset_at` → `waiting_for_reset` (carry `reset_at`,
     compute `eta_human` e.g. `"in 4h 55m"`).
   - `lockout` without `reset_at` → `exhausted`.
   - `cooldown` with `Now >= until` → `available`; else `cooling_down` (carry `until`).
   - `limited` → `limited` (a `reset_at` past `Now` expires it to `available`).
   - `clear` → `available`.
3. No events for the worker → `available`.

`Get-AllWorkerStates` returns the same record for every distinct worker seen in the journal
(plus, when a fleet path is supplied, any enabled fleet worker not in the journal → `available`).

`Get-ConserveMode -[Now] -[UsagePath]` → `$true`/`$false` from the latest `conserve` event.

**States:** `available · limited · exhausted · cooling_down · waiting_for_reset`.

---

## 5. Routing integration — route-around-exhausted

`Select-Capability` (routing-lib.ps1) gains one new parameter and one filter step:

- New param: `[string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl')`. When the
  file is absent, the filter is a **no-op** (every worker available) — standalone use and the
  existing test suite are unaffected.
- After the cost-tier / context-floor filter (step 3 today), apply usage:
  - Drop any fleet candidate whose `Get-WorkerState` is `exhausted`, `cooling_down`, or
    `waiting_for_reset`.
  - When `Get-ConserveMode` is `$true`: also drop `limited` candidates **and** force
    `SelectionMode = 'economy'`.
  - Otherwise `limited` candidates stay but are down-ranked (quality multiplied by a fixed
    `0.5` penalty so they sort below equal-tier healthy peers without being removed).
- The filter applies to **fleet** candidates by name. `tools.yaml` candidates are unaffected
  unless a tool name matches a journal worker (forward-compatible; no tool is governed in MVP).

`usage-lib.ps1` is dot-sourced into `routing-lib.ps1` (like `routing-learn.ps1` already is) so
`Get-WorkerState` / `Get-ConserveMode` are in scope.

---

## 6. Forecast — best-effort, honest

`Get-UsageForecast -Worker <name> [-Days 7] [-Now] [-UsagePath] [-FleetPath]` →
`{worker, run_rate, unit, days_with_data, status, days_to_exhaustion?, consumed_window?, budget?}`.

Algorithm:

1. Collect `tick` events for the worker within the last `Days` days; bucket counts by UTC day.
2. `run_rate` = mean count over **days that have ticks** (not calendar days — avoids diluting a
   2-day sample across 7).
3. If `days_with_data < 2` → `status:"insufficient_data"` and stop (still return `run_rate` if 1 day).
4. Read optional per-worker `budget` from the fleet entry (`Get-WorkerBudget`). If absent →
   `status:"rate_only"` (report `run_rate`, no exhaustion date).
5. With a budget: `consumed_window` = sum of ticks since the start of the current reset window
   (window start = the latest `lockout`/`clear` boundary, else the first tick in range);
   `days_to_exhaustion = max(0, (budget - consumed_window) / run_rate)`; `status:"ok"`.

No smoothing, no extrapolation beyond linear run-rate. "Simple" per the brief.

**Budget source & box-privacy:** `budget` is an optional integer field on a fleet worker.
The shared `references/fleet.yaml` seed carries **only a commented placeholder example** — real
budgets are hand-added to the live `~/.baton/fleet.yaml` (same operator step as the triage
providers in Sprint 1). `Get-WorkerBudget` reads it at runtime; absent is fully supported.

---

## 7. CLI — `fleet-usage.ps1` and `/baton:usage`

`scripts/fleet-usage.ps1 <subcommand> [...] [--json]`:

| subcommand | effect |
|---|---|
| `status` | table of every known worker: state, ETA, reason; plus the conserve flag |
| `lockout <worker> [--reset <when>] [--reason <text>]` | append a `lockout` event |
| `limit <worker> [--reset <when>] [--reason <text>]` | append a `limited` event |
| `cooldown <worker> --until <when>` | append a `cooldown` event |
| `clear <worker>` | append a `clear` event |
| `conserve on\|off` | append a `conserve` event |
| `tick <worker> --count <N> [--unit <u>]` | append a `tick` event |
| `forecast [<worker>]` | one worker, or all known workers |

- `--when` values accept ISO-8601 or a relative shorthand (`+5h`, `+2d`, `+90m`) parsed to a UTC
  instant by a small `ConvertTo-UsageInstant` helper.
- Default (no `--json`) output is a deterministic aligned table; `--json` emits
  `ConvertTo-Json -Depth 6`.
- `commands/usage.md` documents `/baton:usage [status|lockout|limit|cooldown|clear|conserve|tick|forecast] ...`
  and shells to `$HOME/.claude/scripts/fleet-usage.ps1`, matching the `/baton:triage` shape.

---

## 8. File map

**Create:**
- `scripts/usage-lib.ps1` — core library (events, state fold, conserve, forecast, budget read).
- `scripts/fleet-usage.ps1` — CLI runner.
- `scripts/test-usage.ps1` — test harness (`Check($n,$c)` pattern).
- `commands/usage.md` — `/baton:usage` slash command.

**Modify:**
- `scripts/routing-lib.ps1` — dot-source usage-lib; add `-UsagePath` + usage filter to `Select-Capability`.
- `references/fleet.yaml` — commented `budget:` placeholder example + taxonomy note.
- `scripts/bootstrap.ps1` — add `usage-lib.ps1`, `fleet-usage.ps1` to the deploy manifest.
- `scripts/test-bootstrap.ps1` — assert both scripts deploy.
- `.claude-plugin/plugin.json` — version bump (rc.8 → rc.9).

---

## 9. Test plan (TDD, ~25–30 checks)

`scripts/test-usage.ps1` — all using a temp BATON_HOME / injected `-UsagePath`, **never** the
real `~/.baton`; `-Now` / `-Timestamp` injected for determinism.

1. `Add-UsageEvent` appends a well-formed row; `Read-UsageJournal` round-trips it.
2. Missing journal → `Read-UsageJournal` returns empty, no throw.
3. Malformed line skipped (Read-JsonlRows contract).
4. Write fault warns, does not crash.
5. `Get-WorkerState` of unknown worker → `available`.
6. `lockout` without `reset_at` → `exhausted`.
7. `lockout` with future `reset_at` → `waiting_for_reset` + `eta_human` non-empty.
8. `lockout` with past `reset_at` → auto-expired `available`.
9. `cooldown` before/after `until` → `cooling_down` / `available`.
10. `limited` → `limited`; with past `reset_at` → `available`.
11. `clear` supersedes an earlier `lockout` → `available`.
12. Latest-event-wins ordering by `ts`.
13. `Get-ConserveMode` toggles on/off across two `conserve` events.
14. `Get-AllWorkerStates` covers every journal worker (+ enabled-but-unseen fleet workers → available).
15. `Add-UsageTick` appends `tick` with default unit `requests`.
16. Forecast `<2` days of ticks → `insufficient_data`.
17. Forecast with ticks, no budget → `rate_only`, correct `run_rate`.
18. Forecast with budget → `ok`, correct `days_to_exhaustion`.
19. Forecast run_rate averages over days-with-data, not calendar days.
20. `ConvertTo-UsageInstant` parses `+5h`/`+2d`/`+90m` and ISO-8601.
21. `Select-Capability` excludes an `exhausted` fleet worker.
22. `Select-Capability` excludes `cooling_down` / `waiting_for_reset`.
23. `Select-Capability` keeps `limited` but ranks it below a healthy equal-tier peer.
24. conserve_mode on → `limited` excluded **and** ranking forced economy.
25. Empty/absent `-UsagePath` → `Select-Capability` unchanged (no-op), existing behavior intact.
26. `Get-WorkerBudget` reads a fleet `budget`; absent → `$null`.
27. CLI `status` renders a deterministic table; `--json` parses.
28. CLI `lockout --reset +5h` produces a `waiting_for_reset` reflected by `status`.

`scripts/test-bootstrap.ps1` — +2 asserts: `usage-lib.ps1` and `fleet-usage.ps1` deploy.

---

## 10. Risks & mitigations

- **Coupling routing-lib to usage state.** Mitigated by the absent-file no-op and an injectable
  `-UsagePath`: every existing routing test runs unchanged with no journal present.
- **Box-private leakage via budgets.** Mitigated by keeping real budgets out of the shared seed
  (placeholder comment only) and in the live fleet.yaml.
- **Forecast over-promising.** Mitigated by explicit `insufficient_data` / `rate_only` statuses;
  the forecast never fabricates an exhaustion date without a budget and ≥2 days of data.
- **State drift if a worker is cleared late.** Acceptable for MVP — manual lockout is operator-
  driven; auto-detection (Sprint 2.5) closes this gap later.
