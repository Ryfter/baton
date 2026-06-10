# Cost-Optimization Engine (design)

**Status:** in review 2026-06-10
**Thesis:** Cost optimization is the founding goal of this project; spreading work across multiple coding platforms is the *strategy* for it. This spec unifies the levers into one engine, delivered in shippable slices.
**Decision lineage:** d026 (cost-optimal multi-model orchestrator), routing optimizer S1–S4 (Lever 1, SHIPPED).

## The four levers

Every lever cuts spend on a different axis. Lever 1 is shipped; this spec builds 2–4.

| Lever | Cuts cost by | Mechanism | Status |
|---|---|---|---|
| **1 — Right capability** | running the cheapest *capable* option, local-preferred | routing optimizer (`Select-Capability`, cost-ascending, learning loop) | **SHIPPED** (S1–S4) |
| **2 — Right time** | not burning frontier $ at peak; doing more when limits are cheap/doubled | prime-peak **rank gate** + weekend/off-peak **capacity surge** | this spec, Slice A |
| **3 — Right decomposition** | spending top-tier compute only on the final delta | **draft-cheap → finish-expensive cascade** | this spec, Slice B/C |
| **4 — Right platform** | using the best-value platform per stage | Claude Code / Codex / local fleets, with role metadata | this spec, threaded through B/C |

## Invariants (must hold across all slices)

1. **Rank ≠ tier.** Rank is *importance + spend-tolerance*, not model power. A rank-1 task that the optimizer can satisfy locally/free runs anytime, free, ungated. Rank only matters at the moment the optimizer would spend on a **frontier (paid) model during a peak window**.
2. **Optimizer-first.** The routing optimizer (Lever 1) runs *first and unchanged* — cost-ascending, local-preferred, cheapest capable wins. The Engine's new machinery layers *after* tier selection.
3. **Gate guards only paid-during-peak.** `local`/`free` dispatches are never gated (they cost nothing regardless of hour). Only a `paid` dispatch *inside a prime window* consults the rank gate.
4. **Fail-open.** Missing/malformed config never blocks work — the gate returns `allow` + a one-time warning. Cost optimization is an *optimization*, never a hard stop on getting work done.
5. **Autonomy-preserving.** "Ask" fires only where a human is present (interactive). Unattended paths resolve "ask" to its rank default and never block on a human.

## The rank model

**Scale: #1 = highest priority/spend-tolerance, #5 = lowest.** Core ranks 1–5 are documented and built. Ranks **0** (emergency, preempt-all, bypass gate) and **6** (frugal floor: local/free only, weekend-only) are *reserved, undocumented, not built* — the rank→policy lookup is a table so they are a one-row addition later, with no structural change.

**Prime-gate policy** (applies only to `paid` dispatch inside a peak window):

| Rank | Peak-window policy (paid) | Default when unattended |
|---|---|---|
| 1 | **ask** | run |
| 2 | **ask** | defer |
| 3 | defer | defer |
| 4 | defer | defer |
| 5 | defer | defer |
| *(0 — reserved)* | *allow (bypass)* | *run* |
| *(6 — reserved)* | *never paid; surge-only* | *defer* |

**Dispatch order** (applies everywhere, all tiers): ascending rank — 1 first … 5 last. So 3/4/5 share the gate policy *defer* but remain distinct in queue order. Default rank for un-ranked work = **3**.

**Prerequisite inheritance:** an item's *effective rank* = `min(own rank, min rank of everything that transitively depends on it)`. A rank-1 task's prerequisites become effective-rank-1 so they run early (and may run at premium) rather than being starved behind the urgent item. This realizes "pre-reqs to run other higher [priority] items earlier."

---

## Slice A — Time-awareness (build-ready)

The per-dispatch **cost gate** and the per-session **capacity profile**, both keyed on one time-window config, wired into every dispatch path.

### A.1 Config — `~/.claude/prime-hours.yaml` (bootstrap-deployed, GitHub-backed)

```yaml
timezone: local            # 'local' or an IANA tz e.g. America/Denver
default_rank: 3            # un-ranked work
windows:
  - name: weekday-peak     # expensive: gate frontier by rank
    days: [Mon,Tue,Wed,Thu,Fri]
    start: "08:00"
    end:   "18:00"
    kind:  peak
  - name: weekend          # cheap + doubled limits: surge
    days: [Sat,Sun]
    kind:  surge
    concurrency_factor: 2  # run more subagents; drain deferred queue
```

`kind: peak` → frontier spend gated by rank. `kind: surge` → capacity scale-up. A clock time in no window = ordinary off-peak (frontier allowed, baseline concurrency).

### A.2 The gate — `scripts/prime-hours.ps1` (pure)

```
Test-PrimeHoursGate -Rank <int> -CostTier <local|free|paid> [-Now <datetime>] [-ConfigPath]
  → @{ decision = 'allow'|'ask'|'defer'; default = 'run'|'defer'; reason; window }
```

Logic: `local`/`free` → `allow`. `paid` outside a `peak` window → `allow`. `paid` inside a `peak` window → rank-table policy (above). `-Now` is injectable so tests are clock-independent. Unknown rank → `default_rank`. Bad/missing config → `allow` (fail-open) + one-time warn. Bad timezone → machine-local.

```
Get-CapacityProfile [-Now <datetime>] [-ConfigPath]
  → @{ concurrency_factor = <number>; surge = <bool>; window = <name|null> }
```

In a `surge` window → that window's `concurrency_factor` (default 2) and `surge=$true`; else `1`/`$false`. Consumers multiply their baseline max-parallel subagent count by this and, when `surge`, prioritize draining deferred (rank ≥ 3) work.

### A.3 Wiring (all four scopes)

The library is pure (returns decisions); the *caller* interprets by context.

- **Routing paid-tier** (`Invoke-RoutedCapability` / `Invoke-RoutedCandidate`): before dispatching a `paid` candidate, call the gate with the item's rank. `defer` → skip that candidate (let the optimizer fall back to the next cheaper capable one, or escalate-to-conductor if none); `ask` → return a `needs-decision` status the command layer surfaces; `allow` → dispatch.
- **Backlog drivers** (`fleet-backlog.ps1`, both serial + concurrent): each task carries an optional `rank` (default 3). Compute *effective rank* (prereq inheritance), dispatch ready items in ascending effective rank, and consult the gate per item (unattended → resolve `ask` to default, `defer` → skip + report "deferred until off-peak"). Read `Get-CapacityProfile` to set max-parallel; on `surge`, raise it and drain deferred items.
- **`/schedule` firings:** a scheduled job carries a rank; on firing, the gate decides allow / defer-to-next-off-peak (unattended semantics).
- **`/fleet` (interactive):** lenient — only consults the gate when the dispatch would hit `paid` in a peak window; then `ask` surfaces a prompt, `defer` warns + suggests off-peak/`--force`. Never nags on `local`/`free` or off-peak work the user explicitly launched.

### A.4 Interactive vs unattended (reconciling "still ask" with autonomy)

"Should I spend premium money right now?" *is* a real decision, so an interactive `ask` is a legitimate interrupt — not a 1/2 nag. Unattended paths never block: `ask` → rank default (1 run, 2 defer); `defer` → skip + report. Same library-pure / command-layer-smarts split the routing judge uses.

### A.5 Errors & testing

**Errors:** fail-open on any config fault (allow + warn); bad tz → local; unknown rank → default_rank; a deferred item is reported, never lost.

**Testing** (`scripts/test-prime-hours.ps1`, injected `-Now`, zero clock dependence): local/free always allow; paid off-window allow; each rank's decision inside a peak window; unattended default resolution; window boundary + day-of-week matching; tz handling; fail-open on missing/garbage config; `Get-CapacityProfile` surge vs baseline; effective-rank prereq inheritance + ascending-rank dispatch order in the driver. Bootstrap test asserts `prime-hours.ps1` deploys.

---

## Slice B — Model-role registry + cascade primitive (roadmap)

Lever 3 + Lever 4. **Goal:** spend top-tier compute only on the final delta.

- **Registry metadata:** `fleet.yaml` / `tools.yaml` entries gain a `role` (`draft` | `bulk` | `finisher`) and platform identity, encoding the ladder: local fleets + Haiku/Sonnet = draft/bulk; Opus / Fable / latest GPT (via Claude Code & Codex) = finisher. This makes the multi-platform spread (Lever 4) first-class data.
- **Cascade primitive:** `Invoke-CapabilityCascade -Capability -Prompt` → fan out N `draft`/`bulk` candidates (reusing `Invoke-RoutedCandidate` + the calibration fan-out), apply a **"good-enough" gate** (the existing heuristic/LLM-judge grader at a configurable threshold), then a single **final pass** on a `finisher` model that extends/rewrites the best draft. Journals each stage; the final-pass spend is the only frontier cost.
- Time-aware: the finisher pass itself runs through Slice A's gate (it's the paid/frontier step).

*Scoped here; gets its own plan when Slice A ships.*

## Slice C — Cascade in the autonomous loop (roadmap)

Wire `Invoke-CapabilityCascade` into the backlog driver / autonomous run-loop so unattended work auto-decomposes draft→finish across platforms, time- and capacity-aware: cheap drafting fans out off-peak/at-surge; finisher passes are gated by rank at peak. This is the direct on-ramp to the **autonomous run-loop epic** (folder + repo → run to budget/goal).

*Scoped here; gets its own brainstorm/plan after Slice B.*

---

## Build order

1. **Slice A** (this spec, full detail) — time-awareness gate + capacity profile + wiring. Ships the rank field, prime-hours config, and the peak/surge behavior end-to-end.
2. **Slice B** — registry roles + cascade primitive (own plan).
3. **Slice C** — cascade in the autonomous loop (own brainstorm/plan).

Each slice is gated, reviewed, and merged on its own, mirroring the routing optimizer's slice cadence.

## Files (Slice A)

- **Create:** `scripts/prime-hours.ps1`, `scripts/test-prime-hours.ps1`, this spec.
- **Modify:** `scripts/routing-dispatch.ps1` (gate the paid candidate), `scripts/fleet-backlog.ps1` (rank/effective-rank ordering + gate + capacity), `commands/fleet.md` + `commands/route.md` + the `/schedule` path (rank surfacing), `scripts/bootstrap.ps1` + `scripts/test-bootstrap.ps1` (deploy `prime-hours.ps1` + `prime-hours.yaml`), `docs/next-session.md` + memory (closeout).
