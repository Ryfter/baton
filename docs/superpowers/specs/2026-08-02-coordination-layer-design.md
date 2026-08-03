# Coordination Layer — design

**Date:** 2026-08-02  
**Status:** design only — not authorized to build  
**Author:** Grok design pass from operator brief + reconciliation of three same-day facet specs  
**Audience:** any agent or human implementing cross-project arbitration, run lifecycle, or box-wide spend accounting  
**Related:**  
- Local Resource Governor `2026-08-01-local-resource-governor-design.md` (**#154** — absorbed, not discarded)  
- Decouple / run-anywhere `2026-08-01-decouple-claude-run-anywhere-design.md` (**#155** — CLI + supervisor *facets* absorbed; front-door / re-home remain)  
- Dev-root front door `2026-08-02-dev-root-front-door-design.md` (consumer of this tier; not absorbed)  
- System model `2026-07-11-cli-control-plane-system-model-design.md`  
- Style-B broker draft `2026-07-04-style-b-broker-cockpit-design.md` (later; not this v1)  
- Usage Governor `2026-06-16-usage-governor-sprint2-design.md` (API quota sibling — stays)  
- Token telemetry `2026-07-11-direct-model-commands-token-telemetry-design.md` (dispatch observe — feeds this ledger)  
- Decisions: d043 (one stack per box), d051 (Style-A/B seam), d076 (project registry), d102 (supervisor durable / shell swappable)

> **Note on examples.** Host names, model ids, and dollar figures are illustrative. Live fleet roster, budgets, and hardware footprints stay box-private under `$BATON_HOME`.

---

## 0. One-liner

Baton’s missing middle tier is a **single, box-private Coordination Layer**: one state store and one admission primitive for *what is running*, *what local hardware is leased*, *what each project has spent*, and *who waits next*. It arbitrates, records, and reports. It does **not** plan, walk DAGs, or pick workers beyond local-resource admit/deny.

---

## 1. The realisation (why one tier, not three stores)

### Four-tier architecture (operator-named, 2026-08-02)

```
Conductor      thin, deterministic, any-model-or-none      BUILT  (`baton` CLI dispatcher)
Coordination   cross-project state and arbitration          MISSING  ← this spec
Orchestrator   per-project brain, smart model               BUILT  (`fleet-go.ps1` / go path)
Instruments    fleet labor                                  BUILT  (fleet providers + executor)
```

Naming note (avoid historical drift): older docs call the go-engine “Conductor.” In **this** four-tier model, **Conductor = the thin CLI front door**; the go-engine is the **Orchestrator**. The durable core d102 named “run supervisor” is **this Coordination Layer’s run facet**, not a fifth product.

### Three same-day facet specs = one tier

| Spec / idea | What it actually is |
|---|---|
| Local resource governor (#154) | Cross-project **arbitration** — admission, leases, project weights |
| Run supervisor (#155 phase 1+ / d102 “minimum plumbing”) | Cross-project **run state** — lifecycle, process ownership, status, cancellation, budgets, crash recovery |
| Cross-project token ledger (proposed) | Cross-project **accounting** — where tokens went, what is worth doing next |

Built as three libraries with three stores, each must invent “what is running?” and keep agreeing after crashes. That seam rots. Built as **one tier with one live view**, arbitration, lifecycle, and accounting share facts:

- A run that holds a GPU claim is the same row that reports tokens and the same row a cancel targets.  
- A dead PID frees the claim **and** closes (or marks incomplete) the run **and** freezes ledger accrual for that holder.  
- Project weight is one field, used for wait-queue order and spend advisory ranking — not three copies.

### What this does *not* mean

Unification is **state + admission + report surface**, not a rewrite of Orchestrator brains, Usage Governor API quotas, or the CLI dispatcher. Those remain separate modules that **call into** Coordination for the facts they need.

---

## 2. Tier contract

### Owns outright

| Concern | Meaning |
|---|---|
| **Run registry (live + recent)** | Which orchestrator runs exist on this box, lifecycle status, holding PID, project, budget posture, last heartbeat |
| **Local resource leases** | Who may load which `(host, stack, load_profile)` right now (d043 enforcement) |
| **Project weights** | Coarse priority numbers used for wait-queue order (and display) |
| **Box-wide spend ledger** | Append-only accounting of tokens/cost attributed to runs and projects |
| **Cross-project observations** | Status / doctor / advisory folds over the above — the only honest multi-project “what’s happening?” |
| **Admission serialization** | The short CreateNew critical section that makes multi-file RMW safe |

### Must never own

| Non-goal | Owner instead |
|---|---|
| Task DAGs, planning, revise, Kahn walk | Orchestrator (`conductor-lib` / `fleet-go`) |
| Capability ranking, learned routing, quality_first failover | Routing + Usage Governor |
| API lockouts / conserve_mode / worker forecast | Usage Governor (`usage-journal.jsonl`) — sibling, not absorbed |
| Instrument invoke transport (stdin, prompt files, worktrees) | Fleet / executor |
| Human merge word, PR open, auto-ship | Human + existing gates — **never** this layer |
| Conversational narration / coaching tone | Optional Conductor shells |
| Style-B broker queue / interrupt inbox product | Style-B draft (later); Coordination only exposes run rows the broker can write |
| Live GPU sensing as admission brain | Operator-declared profiles (governor decision preserved) |
| Becoming a second “smart” model that re-plans across projects | Explicitly forbidden — **no model required** for this tier’s verbs |

### Contract in one paragraph (implementer scope-creep test)

> **Coordination is the box’s shared clipboard of concurrent truth.** Anything that needs to know “what runs share this machine, what they hold, and what they cost” reads or mutates Coordination. Anything that decides *what to build next inside a project* stays in the Orchestrator. If a proposed feature requires a smart model, a DAG, or a merge, it is not Coordination.

### Placement in the control plane

```
Operator / agent / dashboard
        │
        ▼
  Conductor (`baton` CLI)  ─── thin verbs, --json
        │
        ▼
  ★ Coordination Layer     ─── admit / register / heartbeat / ledger / report
        │
        ├──► Orchestrator (per-project go) ──► Instruments
        └──► other engine verbs (usage, fleet doctor, …) that only *read* or *tick*
```

Local admission sits **after** a local candidate is chosen (or as a filter that can demote local), same family as usage route-around — one chokepoint before local invoke. Non-local paths never consult resource leases.

---

## 3. One state store

### Location

**Box-private only:** under `$BATON_HOME` (default `~/.baton`). Never the knowledge repo, never project trees.

```
$BATON_HOME/
  coordination/                    # NEW — single tier root
    config.json                    # optional overrides (TTLs, fail policy, weights path)
    locks/                         # short CreateNew critical sections only
      admit__runs.lock
      admit__resource__<host>__<stack>.lock
      admit__weights.lock          # rare: weight file rewrite
    live/
      runs/
        <run_id>.json              # live + recently terminal registry rows
      claims/
        <claim_id>.json            # live local-resource leases (governor store, rehomed)
    weights.json                   # project_id → weight (or path to registry fold)
    journal/
      coord.jsonl                  # optional audit: grant/deny/register/close/cancel
      ledger.jsonl                 # spend accounting (append-only)
  runs/
    <run_id>/                      # EXISTING orchestrator artifacts (plan, events, report)
      …                            # Coordination does not replace these
  usage-journal.jsonl              # EXISTING API-quota governor — stays sibling
  fleet.yaml                       # EXISTING
```

**Why not stuff everything into `$BATON_HOME/runs/` alone?**  
Per-run artifact dirs are the Orchestrator’s durable work product (Style-A/B seam). The Coordination **registry** is a small, concurrent, multi-writer index of *live process truth*. Mixing them forces every claim/renew through large tree walks and confuses “artifact history” with “who holds the GPU.” Registry rows **point at** `runs/<run_id>/`; they do not replace it.

**Migration posture:** v1 may symlink or dual-write `live/claims` from the governor’s previously planned `$BATON_HOME/local-resource/` path for one release if that code already exists; the **canonical** home is `coordination/`. Do not leave a permanent second lease store.

### Live run row (`live/runs/<run_id>.json`)

```json
{
  "schema": 1,
  "run_id": "go-2026-08-02T12-00-00",
  "kind": "go",
  "project": "my-dashboard",
  "project_id": "my-dashboard",
  "goal_summary": "slug permalinks for storylines",
  "status": "running",
  "phase": "labor",
  "holder_pid": 18432,
  "holder_started_at": "2026-08-02T11:59:50Z",
  "holder_name": "pwsh",
  "started_at": "2026-08-02T12:00:00Z",
  "heartbeat_at": "2026-08-02T12:05:00Z",
  "expires_at": "2026-08-02T12:06:00Z",
  "ttl_sec": 60,
  "budget_cap_usd": 15.0,
  "spend_usd_est": 2.4,
  "tokens_in": 120000,
  "tokens_out": 18000,
  "weight": 100,
  "artifact_dir": "runs/go-2026-08-02T12-00-00",
  "cancel_requested": false,
  "close_reason": null,
  "updated_at": "2026-08-02T12:05:00Z"
}
```

**Status enum (v1):**  
`starting` · `running` · `paused` (structural interrupt / parked) · `cancel_requested` · `completed` · `failed` · `abandoned` (crash/TTL) · `canceled`

Terminal rows may remain under `live/runs/` for a short retention window (e.g. 24h or last N) for `status`/`spend` folds, then deleted or ignored by live filters. Full history stays in `runs/<id>/` + `ledger.jsonl`.

### Claim row

Unchanged in spirit from the governor spec — rehomed path only. Fields: `claim_id`, `host`, `stack`, `load_profile`, `vram_gb`, `class`, `run_id`, `project`, `weight`, `holder_pid`, `holder_started_at`, `acquired_at`, `renewed_at`, `expires_at`, `ttl_sec`.

### Weights file

```json
{
  "schema": 1,
  "default": 100,
  "projects": {
    "my-dashboard": 200,
    "atomicforge": 100,
    "background-job": 50
  }
}
```

Resolution for a run: explicit `--local-weight` / `--weight` → project entry → `default`. Same scale as governor: `100` normal, `200` watching, `50` overnight.

### Ledger line (`journal/ledger.jsonl`)

Append-only; one JSON object per line. See §6 for fields and folds.

### Concurrent read/write safety

**Single locking scheme:** the portable atomic file-claim already chosen in the governor and shipped in `window-service-lib.ps1` (`[System.IO.FileMode]::CreateNew`).

| Operation | Lock key | Under lock |
|---|---|---|
| Register / heartbeat / close / cancel-flag run | `admit__runs` | recompute dead runs; write/update/delete one run row |
| Acquire / renew / release resource claim | `admit__resource__<host>__<stack>` | reclaim stale claims; capacity check; write claim |
| Rewrite weights | `admit__weights` | temp+rename `weights.json` |
| Append ledger / coord journal | **none** | append-only JSONL (same discipline as usage-journal); readers skip malformed lines |

**Rules (normative):**

1. **No second locking scheme.** No Windows named mutex, no flock-only path that Windows cannot share, no SQLite required in v1.  
2. **Admission lock is not the lease.** Lock TTL short (default **5s**); lease/run heartbeat TTL longer (default **60s**).  
3. **RMW of a *set* always under the matching lock** (capacity over all claims; “is this PID still the holder?”).  
4. **Claim and run files written via temp + rename** after the decision.  
5. **Stale lock reclaim:** CreateNew fails → read payload → if `expires_at < now` **or** holder PID dead / start-time mismatch → delete lock, retry once. Same as governor.  
6. **Process liveness:** `Get-Process` + start-time when available; if start-time unknown → **TTL-only reclaim** (never early-steal). Portable across Windows / Linux / macOS under PowerShell 7.  
7. **`$BATON_HOME` must be a local disk** for CreateNew atomicity (governor A7). Not NFS/SMB multi-writer.

**Do not reintroduce a Windows named mutex** — already rejected by governor revision + decouple §5.

---

## 4. Reconciliation with merged / in-flight specs

### Legend

| Tag | Meaning |
|---|---|
| **keep** | Decision remains valid in its original home; Coordination does not change it |
| **absorb** | Decision moves into Coordination as the implementation home; original spec is historical for that part |
| **supersede** | Decision is replaced by this doc’s stronger framing (usually “facet of one tier”) |

### Local Resource Governor (`2026-08-01-local-resource-governor-design.md`)

| Decision | Tag | Notes |
|---|---|---|
| Heartbeat leases + short CreateNew admission lock (not daemon) | **absorb** | Same primitive; store under `coordination/live/claims` + `locks/` |
| Fail closed for local when governor/store/lock unavailable | **absorb** | Still local-only; non-local never blocked by Coordination down |
| Unit of contention = load profile on `(host, stack)` | **absorb** | Unchanged admission rules |
| Stack exclusivity (d043) | **absorb** | Unchanged |
| Declared capacity v1 (no NVML as brain) | **absorb** | Unchanged |
| Weights = queue priority, **no preemption** | **absorb** | Weights file becomes shared tier state |
| Default on_deny = visible re-route + journal | **absorb** | Journal may land in `coord.jsonl` *and* run events |
| PID + start-time reclaim; never human file-delete for crash recovery | **absorb** | Shared with run abandon path |
| Portable pwsh 7 only; no named mutex | **absorb** | Binding for whole tier |
| Integration chokepoint at local dispatch / Select-Capability | **keep** | Still the call site; library name becomes coordination-lib |
| Separate `$BATON_HOME/local-resource/` tree as permanent home | **supersede** | Rehome under `coordination/` |
| Standalone product identity “Local Resource Governor” | **supersede** | Becomes the **resource facet** of Coordination; CLI may keep alias verbs |
| Optional wait queue + weight ordering | **absorb** (later than v1 core) | Same as governor “later”; not required for stampede-proof day 1 |
| Sticky run-level model residency | **keep** (excluded) | Still not v1 |
| Live thermal soft gates | **keep** (excluded) | Still not v1 |

**Preserved minimums (operator + two reviewers):** fail-closed local · weights no preemption · visible re-route · declared capacity · CreateNew · no dashboard requirement.

### Decouple / run-anywhere (`2026-08-01-decouple-claude-run-anywhere-design.md`)

| Decision | Tag | Notes |
|---|---|---|
| Primary front door = `baton` CLI over existing runners | **keep** | Conductor tier; not this layer’s job |
| MCP = client of same dispatcher | **keep** | Coordination verbs get `--json` for free when on CLI |
| Claude / coding CLIs = optional shells + instruments | **keep** | |
| d102: supervisor durable, shell swappable | **absorb** | “Supervisor” = Coordination run facet + thin process ownership |
| File-based Style-A/B seam for run artifacts | **keep** | `runs/<id>/` remains orchestrator artifacts |
| Phase 1 CLI dispatcher (`go`, fleet, job, …) | **keep** | Coordination adds verbs; does not replace Phase 1 |
| `baton runs show` poll pattern for long MCP go | **absorb** | Becomes real against Coordination registry |
| Portable file leases for cross-process lock | **absorb** | Same scheme as governor; one lib |
| Reject governor-on-named-mutex | **keep** | Reinforced here |
| Cost default flips (free/local first, quality floors) | **keep** | Routing/config; ledger only *observes* outcomes |
| Style-B broker slice 1 (queue + interrupts) | **keep** (later) | Broker writes registry rows / park status via Coordination APIs when built |
| Full web cockpit / multiplexer / resident shell | **keep** (excluded) | Two independent NARROW reviews: minimum plumbing only |
| “Minimum supervisor plumbing” only | **absorb** | v1 scope discipline below |
| Hooks port-by-effect | **keep** | Session markers stay harness adapters; not Coordination brain |
| Re-home script paths / verb contracts | **keep** | Orthogonal engineering |

**#155 Phase 1** remains “ship `baton` dispatcher.” **#155 “phase 1+ run supervisor”** is reframed: implement under this Coordination spec, not as a free-floating third store next to the governor.

### Dev-root front door (`2026-08-02-dev-root-front-door-design.md`)

| Decision | Tag | Notes |
|---|---|---|
| `baton <project>` composition, verbs win, no implicit `--execute` | **keep** | Conductor surface |
| GUI = control board over CLI | **keep** | Dashboard observes Coordination via CLI/`$BATON_HOME` reads |
| Project registry / `.baton/project.yaml` | **keep** | Weights may later fold registry fields; not required for Coordination v1 |

Front door **consumes** Coordination (`baton runs list`, spend advisory) but is not part of the tier.

### Usage Governor + token telemetry (siblings, not superseded)

| Sibling | Relationship |
|---|---|
| `usage-journal.jsonl` | **API quota / lockout / conserve** — fail-open when missing. Remains separate; Coordination ledger may *read* worker states for advisory, never replace lockout math |
| Fleet journal / token fields on dispatch | **Observe-at-invoke** — preferred feed into ledger check-ins; Coordination does not re-parse provider CLIs |
| Per-run `effective-cost.json` | Project-quality join surface — ledger may reference `run_id` and fold later; v1 can live without effective-cost |

**Asymmetry preserved:**  
> API quota governor: fail open. Local resource (Coordination resource facet): fail closed on local only.

---

## 5. Orchestrator check-in protocol

### Design goals

1. **Not chatty** — O(1) writes per phase, not per token.  
2. **Not blocking** for accounting — a run must not fail because the ledger is busy.  
3. **Fail-closed only where stampede risk exists** — local resource acquire.  
4. **Crash-tolerant** — kill/Ctrl+C/reboot leave reclaimable state without human file surgery.  
5. **Same process model** — runs are separate OS processes (governor A2).

### API surface (in-process library; names illustrative)

| Call | When | Blocking? | On Coordination unavailable |
|---|---|---|---|
| `Register-CoordRun` | Orchestrator start (after run_id + artifact dir known) | Short lock | **Soft-fail:** continue run; mark `coord=degraded` in local events; no registry row |
| `Send-CoordHeartbeat` | Every `ttl/3` while running | Short lock | Soft-fail; count consecutive misses |
| `Report-CoordSpend` | After each task / dispatch batch (or periodic ≤ every 30–60s of labor) | Append ledger + optional run-row patch | Soft-fail; buffer last snapshot in run dir `coord-pending.json` for best-effort flush at end |
| `Set-CoordRunStatus` | Phase changes, pause, complete, fail | Short lock | Soft-fail |
| `Request-CoordCancel` | Operator/CLI cancel | Short lock | Hard error to CLI if cannot set flag; run may not see it |
| `Acquire-LocalResource` | Before local invoke | **Must** win lock or deny | **Fail closed for local** (re-route or fail task) |
| `Renew-LocalResource` / `Release-LocalResource` | During/after local invoke | Short lock | Release best-effort; stale TTL reclaims |
| `Close-CoordRun` | Finally block | Short lock | Soft-fail; TTL → `abandoned` |

### Check-in cadence (v1 defaults)

```
register          once at start
heartbeat         every 20s (ttl 60s)
spend report      on task boundary OR every 60s during long labor, whichever first
status            on phase change (plan / gate / labor / verify / complete)
close             once in finally
resource acquire  per local dispatch (governor v1: not sticky run-level)
```

### Non-blocking accounting

- Ledger append is **best-effort**. Orchestrator keeps authoritative per-run totals in memory and in `runs/<id>/` artifacts (`report.md`, future token fields).  
- If `Report-CoordSpend` fails, write `artifact_dir/coord-pending.json` and retry on next heartbeat/close.  
- **A run never exits non-zero solely because Coordination accounting failed.**

### Cancellation (minimum)

1. CLI sets `cancel_requested: true` on the live row (under runs lock).  
2. Orchestrator observes on heartbeat or task boundary (not a signal-forced kill in v1).  
3. Orchestrator drains current non-destructive step policy as today, then `Close-CoordRun` with `canceled`.  
4. **No preemption of in-flight local inference** beyond normal process death → TTL reclaim.

Hard kill remains an OS fact; Coordination recovers via PID/TTL, not cooperative cancel.

### When a run dies mid-flight

| What | Recovery |
|---|---|
| Process killed | Heartbeats stop; next register/heartbeat/status **or** `baton coord doctor` reclaims: status → `abandoned`, claims deleted, no further ledger lines from that PID |
| Partial ledger | Last successful spend line stands; optional close line with `incomplete: true`, `close_reason: "abandoned"` when reclaimer runs |
| Partial claim write | Malformed claim skipped; lock TTL recovers critical section |
| Reboot | All PIDs invalid; cold start empty live claims; terminal abandon of leftover live runs on first doctor/status |
| Accounting honesty | Abandoned runs contribute **only confirmed** ledger lines; UI shows `incomplete` so the operator does not treat them as full cost of intent |

**Never** invent tokens for work that was not journaled. Under-count on crash is acceptable; over-count is not.

### Degraded mode summary

| Facet | Coordination down / unreadable |
|---|---|
| Local resource | **Deny local** (fail closed); free/paid still run |
| Run registry | Soft-fail; single-project orchestrator continues; cross-project status incomplete |
| Ledger | Soft-fail; per-run artifacts still hold truth for that run |
| Weights | Default 100 if unreadable |

---

## 6. Cross-project accounting (minimum ledger)

### The question it must answer

> **Across all my projects, where did the tokens go, and what is worth doing next?**

Not: a pretty chart product. Not: a perfect forecast of model quality. Not: multi-tenant billing.

### What one ledger line records

```json
{
  "ts": "2026-08-02T12:10:00Z",
  "event": "spend",
  "run_id": "go-2026-08-02T12-00-00",
  "project": "my-dashboard",
  "provider": "codex",
  "model": "gpt-5.5",
  "cost_tier": "paid",
  "role": "labor",
  "tokens_in": 40000,
  "tokens_out": 6000,
  "tokens_basis": "exact",
  "cost_usd_est": 1.2,
  "cost_basis": "catalog|provider|unknown",
  "task_id": "t2",
  "outcome": "ok",
  "quota_posture": "available"
}
```

Also allowed events:

| `event` | Purpose |
|---|---|
| `spend` | Accrual (above) |
| `run_open` | Registry mirror for folds without scanning live/ |
| `run_close` | Terminal status, final totals, `incomplete?` |
| `local_denied` | Resource facet visibility (may also be in coord.jsonl) |
| `note` | Rare operator annotation (manual adjust — v1 optional) |

### Per-run rollup (derived, not a second source of truth)

From ledger + live/terminal run row:

- tokens in/out sum, cost est sum  
- by provider, by cost_tier, by role  
- status / incomplete flag  
- project weight at close (snapshot)

### Quota posture fold-in

On each spend (or on advisory render):

1. Read Usage Governor `Get-WorkerState` for `provider` (fail-open if journal missing).  
2. Store `quota_posture` on the line (`available|limited|cooling_down|waiting_for_reset|exhausted|unknown`).  
3. Advisory can say: “my-dashboard burned paid codex while claude was in lockout — expected” vs “both healthy and still all paid.”

Coordination **does not** write lockouts; it only snapshots posture for the spend story.

### Advisory output (what `baton spend` / `coord advise` prints)

Concrete v1 shape (`--json` object):

```json
{
  "window": { "from": "...", "to": "...", "days": 7 },
  "totals": {
    "cost_usd_est": 42.5,
    "tokens_in": 900000,
    "tokens_out": 120000,
    "runs": 18,
    "incomplete_runs": 2
  },
  "by_project": [
    {
      "project": "my-dashboard",
      "cost_usd_est": 28.0,
      "tokens_in": 600000,
      "runs": 10,
      "completed": 7,
      "failed": 2,
      "abandoned": 1,
      "share": 0.66,
      "weight": 200,
      "top_providers": ["codex", "claude-sonnet"],
      "paid_share": 0.81
    }
  ],
  "by_provider": [ { "provider": "codex", "cost_usd_est": 30.0, "quota_posture_now": "available" } ],
  "by_tier": { "local": 0.05, "free": 0.14, "paid": 0.81 },
  "signals": [
    {
      "kind": "concentration",
      "severity": "info",
      "text": "66% of 7d spend is my-dashboard (weight 200)."
    },
    {
      "kind": "paid_dominance",
      "severity": "warn",
      "text": "81% paid-tier while local denials=0 — local capacity unused or unconfigured."
    },
    {
      "kind": "abandon_rate",
      "severity": "warn",
      "text": "3/18 runs abandoned incomplete — crash or kill mid-flight; ledger under-counts those."
    }
  ],
  "worth_doing_next": [
    {
      "suggestion": "prefer_local_or_free_for",
      "project": "background-job",
      "why": "low weight, high paid share, no recent acceptance wins in ledger window"
    },
    {
      "suggestion": "finish_or_drop",
      "project": "my-dashboard",
      "why": "largest spend share; 1 abandoned + 2 failed in window — inspect last report.md before more paid labor"
    }
  ]
}
```

### What the ledger will **not** try to predict

| Explicit non-goal | Why |
|---|---|
| Future quality of a project if you spend $X more | No outcome model; gates already measure quality after the fact |
| Optimal multi-armed bandit across projects | One human operator; weights + advisory are enough |
| True vendor invoice reconciliation | Estimates + provider-reported tokens; catalogs lie |
| Real-time burn graphs / anomaly ML | Commodity dashboards; CLI fold is enough |
| Automatic budget cuts or auto-cancel of other projects | Policy surprise; operator cancels |
| Replacing Usage Governor forecasts | Different resource (API quota vs box spend story) |

**“Worth doing next” is advisory ranking over past spend + status + weight + quota posture**, not a planner.

---

## 7. Surfaces (CLI only)

Standing rule: any GUI is a control board **over** these verbs (subprocess or file read of the same store). No parallel Python reimplementation of admission.

### Verbs (add to `verbs.yaml` / dispatcher)

Prefer a small umbrella plus aliases so agents discover one noun.

| Verb | Purpose | Primary `--json` result |
|---|---|---|
| `coord status` | Live runs + live claims + weights summary | `{ runs: [...], claims: [...], weights: {...}, degraded: bool }` |
| `coord doctor` | Reclaim stale runs/claims/locks; report inconsistencies | `{ reclaimed_runs, reclaimed_claims, stale_locks, issues: [...] }` |
| `runs list` | Filterable run registry (live + recent terminal) | `{ runs: [{ run_id, project, status, spend_usd_est, ... }] }` |
| `runs show <id>` | One run row + pointer to artifact_dir | `{ run: {...}, artifact_dir, claims: [...] }` |
| `runs cancel <id>` | Set cancel_requested | `{ run_id, cancel_requested: true }` or error |
| `spend` / `coord spend` | Ledger advisory over window | Object in §6 |
| `local-resource status` | **Alias** → resource subset of `coord status` | same fields subset |
| `local-resource doctor` | **Alias** → resource reclaim subset of `coord doctor` | |
| `local-resource release-stale` | Force reclaim expired claims (also in doctor) | `{ released: [...] }` |

Human text formatters sit on the same objects. Exit codes: `0` ok, `1` runtime error, `2` bad usage / unknown id (match baton house style).

### What agents consume

- Start long work → poll `baton runs show <id> --json`  
- Before local-heavy batch → `baton coord status --json`  
- Budget conversation → `baton spend --days 7 --json`  
- Never parse dashboard HTML

### Library (implementation shape)

```
scripts/coordination-lib.ps1     # register, heartbeat, spend, acquire, doctor folds
scripts/fleet-coord.ps1          # CLI runner for coord / runs / spend
# local-resource-* may thin-wrap the same lib for alias verbs
```

Extract shared `Request-AtomicFileClaim` from window-service **or** copy CreateNew shape once into coordination-lib — do not drag window-service project semantics into Coordination (governor open point, absorbed).

---

## 8. Failure and portability

### Fail-closed vs degrade

| Situation | Behavior |
|---|---|
| Cannot take resource admission lock / store unreadable | **Deny local**; re-route or fail task; journal if possible |
| Cannot take runs lock | Soft-fail registry updates; orchestrator continues; `degraded` on next successful doctor |
| Ledger append fails | Soft-fail; pending file in artifact dir |
| Config / profiles missing | No local row admittable (fail closed for local eligibility) |
| Weights missing | Default 100 |
| Start-time unavailable | TTL-only reclaim (never steal live) |
| Clock skew on one box | UTC; short lock TTL; lease TTL 60s tolerates small skew |
| Partial deploy (old orchestrator without check-in) | Local path that sees `cost_tier: local` **must** call acquire once Coordination ships (hard dep); registry optional until orchestrator wired |
| Coordination completely absent on a single-project box | Orchestrator still runs; only multi-project arbitration/status missing; **local ungoverned only if acquire not wired** — wiring is the stampede fix |

**Invariant:** an unavailable Coordination layer must never silently permit a local-resource stampede, and must not make a single-project non-local run impossible.

### Portability

| Facility | Requirement |
|---|---|
| OS | Windows, macOS, Linux |
| Runtime | PowerShell 7 |
| Paths | `Join-Path` / .NET only; no hard-coded `D:\` |
| Locks | CreateNew file claims only |
| Process table | `Get-Process`; start-time best-effort |
| Scheduler | Not required for Coordination v1 (no daemon) |

---

## 9. v1 — small enough for a couple of days

Stampede-proof + honest multi-project “what’s running / what did it cost” without Style-B, cockpit, or wait-queue sophistication.

| # | Deliverable | Done when |
|---|---|---|
| 1 | `coordination-lib.ps1`: CreateNew locks, run register/heartbeat/close, claim acquire/release, PID+TTL reclaim | Hermetic tests with temp BATON_HOME + fake process table |
| 2 | Profiles + host capacity config (seed primary host) | Same admission rules as governor §2 |
| 3 | Wire local dispatch → Acquire; deny → visible re-route + journal | Two concurrent conflicting profiles cannot both grant |
| 4 | Wire `fleet-go` / Initialize-RunDir → Register + Heartbeat + Close (soft-fail) | Kill run → abandon within TTL; claim freed |
| 5 | `ledger.jsonl` + `Report-CoordSpend` on task boundary (best-effort) | Lines appear for a stubbed run |
| 6 | CLI: `coord status`, `coord doctor`, `runs list`, `runs show`, `spend --days` | `--json` schemas stable enough for agents |
| 7 | Alias `local-resource status|doctor|release-stale` | Governor mental model preserved |
| 8 | Docs pointer in roadmap / COMMANDS | Operator finds verbs |

**Success criteria**

1. Concurrent process A holds `model-large`; B’s conflicting broad profile is denied and re-routes — never double-loads.  
2. A killed → claim free within TTL (sooner if PID dead); run row → `abandoned` without manual delete.  
3. `baton spend --days 7 --json` answers where tokens went by project/provider/tier.  
4. Coordination store deleted → local denied; paid/free still dispatch; single `go` still completes.  
5. Same behavior under pwsh 7 on Windows, Linux, macOS (hermetic process table).  
6. No new dashboard; no auto-merge; no preemption; no NVML brain.

---

## 10. Deliberately excluded

| Excluded | Why |
|---|---|
| Always-on Coordination daemon | File leases + heartbeats suffice; NARROW “minimum plumbing” |
| Windows named mutex / `Global\` | Non-portable; already rejected |
| Second locking scheme (SQLite, flock-only, generation CAS as primary) | Complexity without gain for one operator box |
| Style-B broker / interrupt inbox / cockpit product | Separate draft; later |
| Wait-queue fairness beyond optional later | Stampede-proof does not need it day 1 |
| Preemption of in-flight local work | Surprising; operator can kill |
| Live GPU sensing as admission authority | Declared capacity only |
| Sticky multi-task model residency | Optimization, not safety |
| Auto-merge / auto-cancel other projects by spend | Human control law |
| Predicting project ROI / quality | Ledger is retrospective + advisory |
| Absorbing Usage Governor into Coordination store | Different fail mode (open vs closed); different resource |
| Replacing `runs/<id>/` artifacts | Orchestrator seam must stay |
| Multi-box distributed locks / network protocol | One box, local disk |
| Shared NFS/SMB `$BATON_HOME` | CreateNew not trustworthy |
| Full token-accurate vendor invoices | Estimates + reported tokens only |
| Per-provider-row locks only | Misses multi-row same-server thrash |
| Weighted fair GPU-second marketplace | Overkill |
| Chatty per-token check-ins | Process noise and lock contention |

---

## 11. Assumptions (flagged)

| # | Assumption | If wrong |
|---|---|---|
| A1 | One human operator; coarse project weights are enough | Fair-share scheduling can wait |
| A2 | Concurrent runs = separate OS processes | In-process fan-out still uses same API |
| A3 | Local dispatch can be forced through one acquire chokepoint | Bypass paths stampede; doctor must warn |
| A4 | `$BATON_HOME` on local disk of the GPU box | Remote host needs later RPC — out of v1 |
| A5 | Operator accepts under-count on crash rather than invented spend | If not, require durable pre-dispatch reservations (heavier) |
| A6 | Soft-fail registry is acceptable so single-project work never depends on Coordination | If registry becomes load-bearing for cancel safety, tighten later |
| A7 | Declared VRAM profiles stay honest enough | Same honesty model as budgets |
| A8 | Unifying three facets now is cheaper than reconciling three stores after each ships | See §12 critique |
| A9 | Phase-1 `baton` CLI exists or lands first so verbs have a home | Coordination can ship as `fleet-coord.ps1` until dispatcher merges |
| A10 | Budget drop is primarily one paid vendor; free/local/other seats still matter | Advisory still useful as concentration report |

---

## 12. Where this might be wrong

### Unification premature?

**Steelman for keeping three stores:**

1. **Different fail modes** already force asymmetric code paths (local closed vs ledger open). One library with three policies can become a pile of flags.  
2. **Shipping pressure:** stampede-proof local claims is a 1–2 day vertical; full registry + spend advisory stretches “couple of days.” A pure governor ship unblocks concurrent runs sooner.  
3. **Usage Governor already exists** as a journal; a third journal for spend is fine if run_id is the join key — “must share a store” is weaker than “must share a run_id.”  
4. **NARROW reviews** warned against supervisor scope; naming a “Layer” invites gravity (cockpit, fairness, multi-box).

**Why this spec still unifies (weakly, as state not product):**

1. The rot is real: claim.holder, run.pid, and ledger.run_id **are the same fact**. Three reclaim implementations will drift (one reclaims PID, another forgets abandon, third keeps accruing).  
2. v1 can ship **one lib, three facets, thin CLI** without a daemon or UI — the NARROW constraint is honored if §9 stays the ceiling.  
3. If schedule forces a split, **implement resource facet first inside `coordination/` paths** so the second facet does not invent `local-resource/` forever.

**Recommendation:** treat Coordination as the **directory + lock + run_id contract** even if the first PR only lands claims + doctor. Do not open three top-level stores.

### Other critique points

1. **Soft-fail registry vs cancel reliability** — Cancel is best-effort cooperative. Hard guarantee needs OS job objects / process groups (portable pain). Acceptable for one operator; document it.  
2. **Ledger double-count risk** — If both dispatch telemetry and orchestrator Report-CoordSpend write spend lines, totals lie. v1 rule: **one writer authority** (orchestrator aggregates dispatch results → single spend lines). Dispatch journals remain detailed debug, not double-booked.  
3. **“Worth doing next” will feel dumb** without acceptance outcomes — fold `effective-cost` / gate verdict when present; until then keep suggestions few and conservative.  
4. **Tier naming collision** — “Conductor” historically = go-engine. This doc’s four-tier rename must land in handoffs/roadmap or agents will mis-wire.  
5. **Weight file vs project registry** — two homes for priority. v1 standalone `weights.json` is fine; later fold `local_weight` into registry to avoid drift.  
6. **If concurrent runs are still rare** — building any of this before finish-rate (green walk) may be sequencing-wrong even if architecture-right. Design now, build when concurrency is real (governor was already called a hard prerequisite for concurrent supervisor — same gate).

---

## 13. Decisions summary (quick table)

| Topic | Decision |
|---|---|
| Tier role | Arbitrate, record, report — never plan or merge |
| State | One tree `$BATON_HOME/coordination/` + existing `runs/<id>/` artifacts |
| Lock | CreateNew only; short admit locks; heartbeat leases |
| Governor | Absorbed as resource facet; rules preserved |
| Run supervisor | Absorbed as run facet; minimum plumbing |
| Token ledger | Absorbed as accounting facet; advisory not predictive |
| Usage Governor | Sibling; not absorbed |
| Check-in | Soft-fail except local acquire fail-closed |
| Crash | TTL/PID reclaim; incomplete ledger; no invented tokens |
| CLI | `coord`, `runs`, `spend`, `local-resource` aliases; GUI over CLI |
| v1 | Claims + run registry + ledger + doctor/status/spend in ~couple days |
| Preemption / NVML / cockpit / auto-merge | No |

---

## 14. Open points for implementer (non-blocking)

1. Extract shared CreateNew helper vs copy shape into coordination-lib.  
2. Whether `spend` is top-level verb or only `coord spend` (recommend both: agent-short + umbrella).  
3. Retention of terminal live rows (24h vs last 50).  
4. Exact filesystem-safe encoding of host/stack in lock names (mirror project-key sanitization).  
5. Ensemble of N local providers = N serial acquires (governor open point — keep).

---

## 15. Next step after approval

1. Record a short decision (Coordination = tier 2; governor + supervisor + ledger are facets).  
2. Hand to `writing-plans` → `docs/superpowers/plans/2026-08-02-coordination-layer.md` covering lib, wires, CLI, tests in §9.  
3. Mark governor (#154) and supervisor-parts of #155 as **superseded-for-implementation-home** by this doc (historical design still valuable).  
4. **Do not build** until the operator authorizes — design only.

---

## 16. Supersession notice (for future readers)

When this design is accepted:

- Implement **local resource admission** from this doc + governor rules tables (do not open a parallel `$BATON_HOME/local-resource/` forever).  
- Implement **run registry / cancel / abandon** here, not as a separate supervisor store.  
- Implement **cross-project spend advisory** here, not as a third ledger root.  
- Keep **Usage Governor**, **Orchestrator artifacts**, **CLI dispatcher**, and **front-door** designs in force for their non-overlapping scopes.
