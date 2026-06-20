# Sprint 6 — Worker Adapter (design)

**Date:** 2026-06-20 · **Sprint:** 6 of the Baton v2 economic-conductor MVP ·
**Status:** approved (brainstorm 2026-06-20) · **Plugin:** `1.2.0 → 1.3.0-rc.1`

## 1. Goal

Make `gh models run <model>` a first-class, **self-metering, budget-aware fleet
worker** — closing the **dispatch → meter → forecast → route-around** loop so an
external worker is consumed automatically, without manual `/baton:usage tick`.
This is the roadmap's "run one external worker through Baton routing": the
GitHub Models allotment becomes a saturable labor pool the Usage Governor can
track. The **active saturation driver** (rank-boosting the budgeted worker toward
a utilization target) is explicitly **out of scope** — deferred to its own slice.

## 2. Scope

**In:** a GitHub Models adapter that (1) registers as a normal `cli` provider,
(2) **auto-meters** every real dispatch, and (3) **maps GitHub rate-limit /
quota responses → Usage-Governor states** with the parsed reset ETA. The adapter
seam is generic — a future external worker plugs in by adding one parser, no
query-core change.

**Out (deferred, tracked):** the active saturation/preference driver (boosting
the worker's rank while it has budget headroom); multiple concurrent adapter
types beyond the one GitHub parser; assignee/cost-advisor wiring. Serf is **not**
a target — it was only an illustration of "an external worker"; nothing here
depends on it.

## 3. Architecture

A thin adapter layer **over** existing seams — it adds no new invocation or
routing engine:

- **Invocation** stays `Invoke-Fleet` → `Invoke-Fleet-Cli` (the worker is an
  ordinary `cli` provider with a `command_template`).
- **Routing / route-around** stays `Select-Capability` (Sprint 2 already
  down-ranks `limited` and excludes exhausted workers; absent journal = no-op).
- **Metering** stays the Usage Governor journal (`usage-journal.jsonl`,
  box-private under `$BATON_HOME`).

Everything new is **pure parsing + a seamed wrapper**. The wrapper calls the real
dispatch through an injectable `-Dispatcher` seam, so the hermetic suite never
touches `gh`, the network, or a real journal.

```
/baton:worker run github-models --prompt "…"
  └─ fleet-worker.ps1
       └─ Invoke-Worker            (worker-lib, seamed)
            ├─ Invoke-Fleet         (default -Dispatcher → real gh models run)
            ├─ Add-UsageTick        (auto-meter: only on a real API hit)
            ├─ Get-RateLimitState   (pure parse of output+exit)
            └─ Set-WorkerLimited / Set-WorkerCooldown   (only if limited; with parsed ETA)
  → next Select-Capability routes around the limited/exhausted worker (existing behavior)
```

## 4. Components

### 4.1 `scripts/worker-lib.ps1` (pure + seamed)

**Pure (no I/O, unit-tested):**

- `Get-RateLimitState([string]$Output, [int]$ExitCode) → @{state; until; reason}`
  — the testable heart. Scans the dispatch output + exit code for GitHub rate-limit
  / quota signatures (HTTP 429, "rate limit", "quota", "RateLimitReached", a
  "try again in N" / reset-timestamp phrase) and maps to a Usage-Governor state:
  `cooling_down` (short "try again in N seconds/minutes" → relative ETA),
  `waiting_for_reset` (an absolute reset timestamp), or `limited` (limit hit, no
  parseable ETA). Returns `state='available'`, `until=$null` when no limit is
  detected. **Fail-open:** ambiguous output never produces a limit state — a
  worker is never falsely locked.
- `Test-WorkerAdapter([object]$Provider) → [string]` — returns the provider's
  `adapter` value (e.g. `github-models`) or `$null`. Identifies an adapter-backed,
  metered worker.
- `Get-AdapterParser([string]$Adapter) → [scriptblock]` — tiny dispatch table:
  adapter name → its rate-limit parser. v1 holds exactly one entry
  (`github-models` → `Get-RateLimitState`). Unknown adapter → `$null` (treated as
  unmetered). This is the seam a future external worker plugs into.
- `Test-WorkerApiHit([int]$ExitCode, [hashtable]$LimitState) → [bool]` — did this
  dispatch actually hit the remote API (and therefore consume the allotment)?
  True on success (exit 0) **or** a detected rate-limit; false on a local/auth
  failure (non-zero exit with no limit signature). Drives whether to tick.
- `Format-WorkerReport([hashtable]$Result) → [string]` — plain-English legibility
  line (worker, model, metered?, tick, state change + ETA).

**Seamed (I/O behind injectable params):**

- `Invoke-Worker(-Name, -Prompt, [-Model], [-UsagePath], [-FleetPath],
  [-Dispatcher], [-Dry]) → @{output; exit; metered; adapter; tick; state; until; reason}`
  — resolves the provider (`Get-FleetProvider`), reads its `adapter`. Calls the
  dispatch via `-Dispatcher` (default `{ param($n,$p,$m) Invoke-Fleet -Name $n
  -Prompt $p -Model $m }`). If the provider is adapter-backed and the dispatch was
  a real API hit (`Test-WorkerApiHit`), **auto-ticks** the journal
  (`Add-UsageTick -Worker $Name -Count 1 -Unit requests`) and runs the adapter's
  parser; on a limit state, writes it via `Set-WorkerLimited` /
  `Set-WorkerCooldown` (using the parsed ETA). Unmetered providers pass through
  untouched (output only). `-Dry` skips all journal writes (preview).

Reuses, never re-implements: `Get-FleetProvider` (fleet-lib), `Add-UsageTick` /
`Set-WorkerLimited` / `Set-WorkerCooldown` / `Get-WorkerState` /
`Get-UsageForecast` / `Get-WorkerBudget` (usage-lib).

### 4.2 `scripts/fleet-worker.ps1` (CLI)

Subcommands:

- `run <name> [--model M] [--prompt "…" | --file PATH] [--dry] [--json]`
  — metered dispatch through `Invoke-Worker`; prints `Format-WorkerReport` (or
  JSON). `--dry` previews (no journal writes).
- `status [<name>] [--json]` — for each adapter-backed worker: current
  Usage-Governor state, budget (box-private, from live fleet.yaml), consumed,
  remaining/headroom, **utilization %**, and the best-effort forecast
  (`Get-UsageForecast`). Worker-centric companion to `/baton:usage status`.

`$BATON_HOME`-derived default paths (box-private); never the knowledge repo.

### 4.3 `commands/worker.md`

`/baton:worker run|status` → shells to `fleet-worker.ps1 <sub> $ARGUMENTS`.
Documents the metered-dispatch + budget-view surfaces.

### 4.4 `references/fleet.yaml` (seed)

Add one provider and document the new field in the header:

```yaml
  - name: github-models
    kind: cli
    enabled: false            # opt-in: enable in your live fleet.yaml
    cost_tier: free
    adapter: github-models    # adapter-backed → auto-metered + rate-limit-aware
    platform: github
    model_default: gpt-4o-mini
    command_template: 'gh models run {{model}} "{{prompt}}"'
    capabilities: [code-gen, summarize-short, classify]
    # budget: <int>           # BOX-PRIVATE — set the real per-window allotment
    #                           ONLY in your live ~/.baton/fleet.yaml, never here.
```

Header gains an `adapter` field note (alongside `role` / `platform` /
`capabilities`): *"(optional) names the worker-adapter that meters this provider
and maps its rate-limit responses to Usage-Governor states; absent = unmetered."*

`budget` stays **null / comment-only** in the shared seed (box-private rule);
real allotment lives in live `~/.baton/fleet.yaml`.

### 4.5 Bootstrap + tests + version

- `scripts/bootstrap.ps1` — add `worker-lib.ps1`, `fleet-worker.ps1` to the
  deploy manifest.
- `scripts/test-bootstrap.ps1` — 2 deploy asserts.
- `scripts/test-worker-lib.ps1` — ~25–30 hermetic checks (see §7).
- `.claude-plugin/plugin.json` — `1.2.0 → 1.3.0-rc.1`.

## 5. Decisions

- **d-wa-1 (adapter marker):** mark a metered worker with an `adapter: <name>`
  field, not a boolean `metered: true`. Names the worker-adapter concept the
  roadmap reuses for the next external worker; worker-lib dispatches the
  rate-limit parser by adapter name. Concept-anchored at n=1 — when a second
  external worker arrives it adds one parser, no field migration. *Alternative:* a
  plain boolean + hard-wired GitHub parser — less code now, but a refactor when
  the second worker lands.
- **d-wa-2 (adapter wrapper, not instrumented dispatch):** metering lives in a
  dedicated `Invoke-Worker` wrapper, not inside the universal `Invoke-Fleet`.
  Keeps the hot dispatch path clean and scopes auto-metering to adapter-backed
  workers only. *Alternative:* instrument `Invoke-Fleet` so every provider meters
  — broader, more invasive, unnecessary for "run one external worker."
- **d-wa-3 (tick on real API hit only):** auto-tick on dispatch success **or** a
  detected 429 (both consume the allotment), never on a local/auth failure. The
  meter tracks real consumption, not attempts.
- **d-wa-4 (fail-open metering):** ambiguous output never writes a limit state;
  the adapter is advisory and never falsely locks a worker out of routing.
- **d-wa-5 (saturation driver deferred):** Sprint 6 ships the metered, routed,
  budget-aware pool; the active rank-boost-toward-utilization driver is a later
  slice. Route-around-when-exhausted already exists (Sprint 2).

## 6. Error handling

- **Local/auth failure** (non-zero exit, no limit signature): return the error,
  **no tick, no state write**. Surfaced in the report.
- **Rate-limit / quota:** tick (it hit the API), write the mapped state with the
  parsed ETA, return the output (which carries GitHub's message). Never throws.
- **Unknown/unparseable ETA on a real limit:** state `limited` with `until=$null`
  (Sprint 2 renders this as a hard-stop with no ETA) — honest, not fabricated.
- **Unmetered provider** routed through `worker run`: pass-through dispatch, no
  metering (a warning that the worker is not adapter-backed).
- Everything is **advisory** — the adapter never blocks a dispatch.

## 7. Testing (hermetic)

`scripts/test-worker-lib.ps1`, ~25–30 checks, **zero network / model / real
journal**:

- **Rate-limit parser** (pure): 429 body → `limited`; "try again in 60 seconds" →
  `cooling_down` with a ~60s ETA; an absolute reset timestamp →
  `waiting_for_reset` with that ETA; clean success → `available`/`null`; a generic
  error (no limit signature) → `available` (fail-open); empty output → `available`.
- **`Test-WorkerApiHit`:** exit 0 → true; 429 detected → true; non-zero + no
  limit → false.
- **`Test-WorkerAdapter` / `Get-AdapterParser`:** github-models provider →
  parser; provider with no `adapter` → `$null`; unknown adapter → `$null`.
- **`Invoke-Worker`** with a stubbed `-Dispatcher` (success fixture): auto-tick
  written to the temp journal; no state change.
- **`Invoke-Worker`** (429 fixture): tick **and** a `limited`/`cooling_down` state
  with the parsed ETA written.
- **`Invoke-Worker`** (auth-failure fixture): **no** tick, **no** state.
- **`Invoke-Worker -Dry`:** dispatch runs, journal untouched.
- **`Invoke-Worker`** on an unmetered provider: pass-through, no journal writes.
- **`Format-WorkerReport`:** renders worker/model/tick/state lines.
- **CLI** (`fleet-worker.ps1` via child process, `BATON_HOME` → temp): `run --dry
  --json` shape; `status --json` shape with utilization %.

Seams: `-Dispatcher` (canned outputs); `-UsagePath` / `-FleetPath` → temp
fixtures. Mirrors the established house pattern (usage-lib Read/Add/Fold;
research-gate / memory-lib seamed `-Searcher` / `-Dispatcher`).

## 8. Box-private compliance

- Real per-window `budget` only in live `~/.baton/fleet.yaml`; seed = null +
  comment.
- The journal stays box-private under `$BATON_HOME`; tests use temp dirs.
- The seed `github-models` entry is a publicly-known free service with a generic
  `model_default` and `enabled: false` — an example, not Kevin's private roster.

## 9. Risks

- **GitHub rate-limit message format drift:** the parser keys off current `gh
  models` output; if GitHub changes wording the parser may miss a limit. Mitigated
  by fail-open (a missed limit just means no auto-lock; the next dispatch's 429
  re-surfaces it) and by isolating the parser behind `Get-AdapterParser` for a
  one-line update.
- **Double-count vs. other callers:** only `Invoke-Worker` auto-ticks; a raw
  `Invoke-Fleet` call to the same provider would not meter. Acceptable for v1 —
  the metered path is `/baton:worker run`; documented.
- **`gh models` availability:** if the extension isn't installed the live smoke
  can't run; the hermetic suite is unaffected (fully stubbed). Live smoke is
  best-effort, gated on availability.
