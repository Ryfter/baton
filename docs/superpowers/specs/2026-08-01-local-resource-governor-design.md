# Local Resource Governor — design

> **Note on examples.** Host names, model identifiers, and VRAM figures in this
> document are illustrative placeholders (`gpu-host-a`, `model-large`, ...). The real
> fleet roster, endpoints, and hardware footprints are box-private and live only in
> `$BATON_HOME`, never in this repository.

**Status:** design only — not authorized to build  
**Date:** 2026-08-01  
**Audience:** any agent or human implementing concurrent-run local admission control  
**Related:** d043 (one model-serving process per box), Usage Governor (API quota, not hardware), `Select-Capability` routing chokepoint, infra inventory (`projects/baton/infra.md`)  
**Problem class:** cross-process **hardware** admission for local model capacity when multiple orchestrator runs share one Windows workstation

---

## Problem (restated)

Today runs are foreground and serial, so local GPU contention never surfaces as a multi-process problem. Concurrent runs make it inevitable:

1. Two runs both dispatch to `cost_tier: local` rows on the same box.
2. Either they load competing models / stacks (the d043 failure mode — dual servers, VRAM spill, thermal stampede), or they thrash one server with alternating model loads (pathological even at "one process").
3. Everything degrades at once. Queueing one run is better than overtaxing the card for all of them.

The existing **Usage Governor** models **API quota / worker availability**. It deliberately does not model VRAM, thermals, process count, or exclusive load profiles. The Local Resource Governor (LRG) is the hardware sibling — same family of "govern before dispatch," different resource.

**Hard constraint (d043, must be enforced at runtime):** exactly one model-serving process per box. Multiple *provider rows* may point at that one server (e.g. `lm-studio` + `lm-studio-small` on `localhost:1234`); two stacks (Ollama + LM Studio) must never both be live candidates on the same GPU host.

---

## Assumptions (flagged)

| # | Assumption | If wrong |
|---|---|---|
| A1 | One primary GPU box for concurrent runs is gpu-host-a (Windows, ~32 GB VRAM, LM Studio primary). gpu-host-b is a separate remote pool (own host key). | Scope becomes multi-host leases earlier; v1 still works per-host. |
| A2 | Concurrent "runs" are separate OS processes (e.g. multiple `fleet-go` / conductor invocations), not only in-process fan-out. | In-process-only concurrency would still benefit from the same API, but the lease store could be simpler; design still holds. |
| A3 | Local dispatch always funnels through `Select-Capability` → invoke (or can be made to). Direct `/baton:models` probes and manual curl are out of band. | Any path that bypasses the chokepoint can still stampede; doctor should warn. |
| A4 | Operator is a single human; project weights are coarse and infrequent, not a multi-tenant fair-share problem. | Weighted fair queueing can wait; v1 priority is enough. |
| A5 | Crash / kill of a run process is common (Ctrl+C, agent crash, reboot). Leases must not stick until manual clear. | Heartbeat TTL is non-negotiable. |
| A6 | Declared load profiles (pinned model + approximate VRAM) are good enough for v1; live NVML sensing is optional later. | If declared footprints lie, operator corrects the registry — same honesty model as budgets. |

---

## 1. Core mechanism — admission primitive

### Chosen primitive: **heartbeat lease file + atomic claim**, not a long-lived supervisor daemon

**What:** A small set of JSON lease records under box-private state (`$BATON_HOME/local-resource/`), protected by a short critical section implemented with a **Windows named mutex** (or equivalent exclusive create of a lock file with PID). The mutex is only held for milliseconds during claim/renew/release — it is **not** the lease itself.

**Why not the alternatives:**

| Alternative | Why rejected for v1 |
|---|---|
| Always-on supervisor process (daemon owns the GPU) | New always-on service to install/monitor; conflicts with "minimum supervisor"; another process that can die and leave ambiguity. |
| Named mutex *as* the lease (hold for whole inference) | A crashed holder can leave the mutex abandoned; recovery semantics are OS-specific and hard to inspect; no room for "which model / which run" metadata. |
| Pure file lock without heartbeats | Stale lock after kill → permanent deadlock until human deletes the file. |
| Kernel semaphore only | No payload (model id, run id, weight); cannot reclaim by TTL; poor observability. |

**Hybrid that works on Windows across independent processes:**

1. **Named mutex** `Global\BatonLocalResource` (or per-host `Global\BatonLocalResource-gpu-host-a`) — serializes *mutations* of the lease store only.
2. **Lease store** — one directory of claim files (or one `leases.json` rewritten under the mutex). Directory-of-files is preferred: a crash mid-write of a single blob is less likely to corrupt all state if each claim is its own file written via temp+rename.
3. **Heartbeat TTL** — every live claim must be renewed periodically by the holding process. Expired claims are free to steal.

This matches patterns Baton already trusts: box-private state under `$BATON_HOME`, append/journal for history, fold/derive for current truth — but leases need *mutable current ownership*, so the live table is separate from an optional audit journal.

### Lease lifecycle

```
  [want local] → Acquire(mutex) → recompute live set (drop expired) →
      if compatible slot free → write claim file → Release(mutex) → RENEW loop → Release on done
      else → Release(mutex) → DENIED (see §4)
```

#### Acquire

1. Enter named mutex (timeout e.g. 2s; if cannot enter → treat as governor unavailable, §6).
2. Load all claim files; discard any with `expires_at < now` (reclaim).
3. Apply admission rules against remaining live claims + request (§2).
4. On grant: write claim file atomically (`claim-<id>.json.tmp` → rename).
5. Leave mutex.
6. Return `{ granted: true, claim_id, expires_at, resource_key, load_profile }`.

#### Renew

- Holding process renews every `ttl/3` (e.g. TTL 30s → renew every 10s).
- Renew path: mutex → if claim still owned by this `holder_pid` + `claim_id` → extend `expires_at` → leave mutex.
- If claim missing or stolen after expiry → renew fails → holder must stop using local and re-acquire or re-route.

#### Release (normal)

- Mutex → delete claim file if `claim_id` + `holder_pid` match → leave mutex.
- Always best-effort on process exit (finally block / `Register-EngineEvent` PowerShell exit).

#### Reclaim after abnormal exit

| Failure | Recovery |
|---|---|
| Holder killed (Task Manager, crash) | Heartbeats stop; after `expires_at`, next acquire reclaims. **No human step.** |
| Holder hung but alive (deadlock inside model call) | Same: TTL expiry. Optional later: OS check that `holder_pid` still exists — if PID gone, reclaim immediately even before TTL. **v1 should do both:** expire on TTL **or** dead PID. |
| Machine reboot | All claims invalid (PID check fails); cold start is empty store. |
| Partial write of claim file | Reader skips unreadable/malformed files (same skip-malformed discipline as JSONL journals). |
| Mutex abandoned (holder died mid-critical-section) | Windows abandons named mutex; next waiter gets it with abandoned flag — treat as success and continue. Do not panic. |

**PID liveness check (Windows):** `Get-Process -Id $holder_pid -ErrorAction SilentlyContinue`. False positive risk: PID reuse. Mitigate by storing `holder_started_at` (process create time) alongside PID; reclaim if create time mismatches. Cheap and reliable enough for v1.

### Where state lives

```
$BATON_HOME/local-resource/
  config.json          # optional overrides (TTL, fail policy); else defaults in code
  claims/
    <claim_id>.json    # live leases only
  journal.jsonl        # optional v1: append grant/deny/release/expire for doctor
```

Box-private only — never the knowledge repo (same rule as usage-journal).

---

## 2. Unit of contention

### Chosen unit: **per load profile on a resource host**, with a **hard exclusive mode bit**

Not "per provider row," not "per GPU process count alone," not fine-grained VRAM accounting in v1.

### Definitions

| Term | Meaning |
|---|---|
| **Resource host** | A physical (or remote) machine that owns a GPU pool. Key: `gpu-host-a`, `gpu-host-b`. Derived from fleet row (`host:` field or inferred from `base_url` / localhost). |
| **Serving stack** | One process family on that host: `lm-studio` *or* `ollama`, never both live as candidates (d043). |
| **Load profile** | A pinned model + declared VRAM budget + concurrency class. Example: `model-large@17g` vs `model-small@11g`. Multiple fleet rows may share one profile if they use the same loaded weights. |
| **Resource key** | `(host, stack)` — e.g. `gpu-host-a/lm-studio`. One stack per host is the d043 invariant. |

### Why load profile (not the other options)

| Unit | Verdict |
|---|---|
| **Per provider row** | Wrong. `lm-studio` and `lm-studio-small` are different rows but share one server; locking per row allows both "rows" to thrash models. Also two rows with the same pin would over-count. |
| **Per GPU** | Too coarse for "big + small both loaded" (allowed inside one server when declared), too fine if multi-GPU later without modeling which models sit where. GPU is the *capacity pool*; profile is the *claim*. |
| **Per loaded model only** | Close, but ignores that two different models on one card contend for VRAM even if "different keys." Need a capacity check across profiles on the same host. |
| **Per VRAM budget (accounting)** | Correct long-term model; too many lying numbers for day-1. Use **declared** profile footprints as a simple sum ≤ `host.vram_gb * safety_factor` in v1, not live NVML. |

### Admission rules (v1)

On host `H` with declared capacity `vram_gb` (from config / infra inventory, default from a small `hosts:` map):

1. **Stack exclusivity:** all live claims on `H` must share the same `stack`. A request for `ollama` while `lm-studio` claims exist → **deny** (or refuse to enable that path — same effect).
2. **Profile compatibility:**  
   - If request's `load_profile` is already loaded (another claim holds the same profile id) → allow up to `max_inflight` concurrent inferences on that profile (default 1 for broad, 2 for tight — config).  
   - If request needs a **different** profile: admit only if `sum(declared_vram of distinct loaded profiles including new) ≤ vram_gb * 0.90`.  
   - If that would require **evicting** an existing different broad profile → **deny** for v1 (no forced unload). Alternating big models is the pathological case; denying the second model protects throughput.
3. **Default posture when unsure:** deny local, do not guess.

Concrete gpu-host-a example (from infra.md):

| Profiles live | OK? |
|---|---|
| `model-large` alone (~17g) | yes |
| `model-small` alone (~11g) | yes |
| `model-large` + `model-small` (~28g of 32g) | yes if both declared and sum ≤ 0.9×32 |
| `model-large` + some other 20g model | no |
| Any ollama claim while lm-studio claims live | no |

**Inflight vs load:** A claim covers **the right to keep a profile loaded and run one (or N) inference(s)**. For v1, simplest correct rule:

- **Acquire for the duration of a single local dispatch** (one HTTP/CLI call), carrying the profile that dispatch will use.
- Optional optimization later: run-level "sticky" lease that keeps a profile warm across many tasks in one run — reduces churn but raises hold time; **not v1**.

This directly stops: two concurrent runs both firing local dispatches that would load different heavy models, and two stacks.

---

## 3. Weights and priority

### Chosen: **queue priority for waiting acquirers**, not preemption of an in-flight lease

**Weight** is an integer per run (or per project, inherited by the run): higher number = higher priority when multiple waiters want a scarce local slot.

| Design | Use in v1? |
|---|---|
| Priority when granting the next free slot | **yes** |
| Weighted fair share of GPU-seconds over a window | no (later) |
| Concurrent slot quotas proportional to weight | no (later; needs multi-slot host) |
| Preempt / cancel in-flight local inference | **no** |

### Behavior when high-weight arrives while low-weight holds a lease

**Let the low-weight holder finish.** Do not kill its inference, unload its model mid-request, or steal the claim before TTL.

**Rationale (single human operator):**

- Preemption surprises the operator ("why did project B's judge fail?") and creates partial work / wasted tokens / thrashing.
- Local inferences are usually short relative to whole runs; waiting is the least surprising semantics — same as "the GPU is busy."
- The operator can always stop a run manually if they want the card now.

### What weight does instead

1. **Wait queue order:** if acquire would deny and the caller chooses to wait (§4), waiters are ordered by weight desc, then enqueue time asc (stable).
2. **Admission preference among simultaneous claims:** if two processes call acquire in the same second for incompatible profiles, higher weight wins the mutex race's grant; lower gets deny/queue. (No perfect fairness under mutex races — good enough for one human.)
3. **Tie-break display:** status/doctor shows weight so the operator sees who is preferred.

### Weight source

```
run weight := explicit --local-weight N on the run
           ?? project registry field local_weight
           ?? default 100
```

Suggested operator scale: `100` normal, `200` "I'm watching this," `50` background overnight. Keep it dumb.

### Explicitly NOT built

- Preemptive eviction of loaded models for higher weight  
- Dynamic weight from stakes / cost remaining  
- Multi-tenant fairness, credits, or "GPU marketplace"  
- Stealing a lease before TTL when the holder is healthy  

---

## 4. When a lease cannot be granted

### Options and recommendation

| Policy | Meaning | Default? |
|---|---|---|
| **Block / queue** | Wait until compatible slot free or timeout | Optional mode |
| **Fail the task** | Local required, hard error | When `RequireLocal` / operator pin |
| **Transparent re-route** | Drop local candidate; let `Select-Capability` pick free/paid | **Default for normal routing** |

### Default: **visible re-route, not silent quality drift**

When local is the *preferred* economy choice but the LRG denies:

1. Mark local candidates **temporarily unavailable for this selection** (same shape as usage governor route-around: filter inside `Select-Capability`).
2. Router continues with free/paid peers per existing rank.
3. **Journal a legible event** every time this happens (not only in a deep log):

```json
{
  "ts": "...",
  "event": "local_denied",
  "host": "gpu-host-a",
  "load_profile": "model-large",
  "run_id": "go-...",
  "project": "my-dashboard",
  "reason": "profile_conflict|stack_exclusive|capacity|governor_unavailable",
  "held_by": ["run-...", "..."],
  "action": "reroute",
  "substitute_tier": "free|paid|none"
}
```

4. Surface to the operator:
   - Run summary line: `local busy → codex (paid)`  
   - Optional coach/statusline one-liner when denials exceed N in a window  
   - `/baton:local-resource status` (v1 CLI, not a dashboard)

### When NOT to re-route

- Caller set **require local** (tests, offline, deliberate local-only ensemble).
- No substitute capability exists → task fails loud with `local-resource-unavailable` (same spirit as labor-unavailable).
- Operator policy `on_deny: queue` with timeout — then block in the acquire helper up to `max_wait`, then fail or re-route per config.

### Recommended defaults

| Setting | v1 default |
|---|---|
| `on_deny` | `reroute` |
| `queue_timeout` | 0 (no wait) for interactive runs; optional `60s` for batch |
| `require_local` | false unless caller says so |
| Visibility | always journal + include in run report |

**Do not silently change cost/quality.** Re-route is allowed, but the fact of re-route is a first-class, operator-visible signal — same honesty bar as usage failover.

---

## 5. Sensing actual load

### v1: **declared capacity only** (reservation model)

| Signal | v1 | Later |
|---|---|---|
| Declared VRAM per load profile | **yes** | refine numbers |
| Declared host VRAM | **yes** | — |
| Live claim count / profiles | **yes** (from lease store) | — |
| GPU util % / temp (NVML) | no | optional advisory |
| Process list of servers | doctor-only check | enforce |
| Power/thermal throttling | no | optional |

### Why not live sensors first (Windows)

| Mechanism | Reliability on this box | Failure modes |
|---|---|---|
| **NVIDIA NVML** (`nvidia-smi` parse) | Works when driver + GPU present | Parse fragility; multi-GPU ambiguity; not installed on pure AMD; slow if called every acquire; can fail open/closed wrongly under driver hang |
| **Performance counters** | Inconsistent for GPU | Often zero or stale for discrete GPU |
| **LM Studio / Ollama APIs** | Good for "what is loaded" | Different APIs; race with JIT load; doesn't see the *other* stack you forgot was running |
| **Declared registry** | Always available, deterministic | Lies if operator mislabels footprint |

**Honesty of declared numbers:**

1. Profiles live next to fleet pins (or a small `local-resource/profiles.yaml`):

```yaml
hosts:
  gpu-host-a:
    vram_gb: 32
    primary_stack: lm-studio
  gpu-host-b:
    vram_gb: 8
    primary_stack: ollama

profiles:
  model-large:
    host: gpu-host-a
    stack: lm-studio
    vram_gb: 17
    class: broad   # broad | tight
    max_inflight: 1
  model-small:
    host: gpu-host-a
    stack: lm-studio
    vram_gb: 11
    class: tight
    max_inflight: 2
```

2. Fleet rows that are `cost_tier: local` **must** reference a `load_profile` (or inherit from `model_default` map). Missing profile → not eligible for local dispatch when governor is enabled (fail closed for that row).
3. `/baton:local-resource doctor` compares declared primary stack to "are both ollama and lm-studio listening?" best-effort — advisory in v1, not the admission brain.
4. When a dispatch OOMs or returns VRAM errors, journal `capacity_lie` and optionally cool that profile — **later**.

**Later sensing (not v1):** optional `nvidia-smi --query-gpu=memory.used,temperature.gpu --format=csv` as a **soft** gate ("if temp > 85°C, deny new broad loads") that can only make the governor *more* conservative, never override stack exclusivity.

---

## 6. Failure mode of the governor itself

### Safe default: **fail closed for local**, fail open for non-local

| Situation | Behavior |
|---|---|
| Lease store unreadable / mutex timeout | Treat as **cannot grant local**. Re-route or fail per §4. **Never** "assume free and dispatch local." |
| Config missing | Use code defaults + if no profiles mapped, **no local row is admittable**. |
| Stale claims | Reclaimed by TTL + dead PID (§1) — not "stuck forever." |
| Governor library not loaded (old deploy) | Same as today = ungoverned; **mitigation:** once shipped, dispatch path that sees `cost_tier: local` **requires** the acquire call (hard dependency), so partial deploys fail loud in doctor/tests. |
| Clock skew | Use UTC; TTL 30s tolerates small skew on one machine. |

**Fail open = the stampede this exists to prevent.** Usage Governor can fail open (missing journal = all workers available) because the downside is overspend on APIs. Here the downside is melting the shared GPU for every concurrent run. Asymmetry is intentional:

> **API quota governor: fail open. Local resource governor: fail closed on local only.**

Non-local paths never consult LRG.

---

## 7. Scope discipline — smallest stampede-proof version

### What actually prevents the thermal stampede

Three rules, enforced at the single chokepoint before any local invoke:

1. **At most one serving stack per host** among live claims.  
2. **No two incompatible broad load profiles** on the same host at once (capacity / exclusivity).  
3. **Dead holders cannot pin the card forever** (TTL + PID).

Everything else is ergonomics.

### v1 (1–2 days of focused build)

| Deliverable | Notes |
|---|---|
| `scripts/local-resource-lib.ps1` | Acquire / Renew / Release / Get-Status; mutex + claims dir; PID+TTL reclaim |
| Profile + host config | Tiny YAML under `$BATON_HOME` or section in fleet; seed for gpu-host-a |
| Wire into local dispatch | Before `Invoke-Fleet` / hatch when selected worker is local: acquire; on deny → re-route once via `Select-Capability` excluding denied profile/stack; journal |
| CLI | `pwsh fleet-local-resource.ps1 status|doctor|release-stale` (mirror `/baton:usage` thinness) |
| Hermetic tests | Fake clock, fake PID table, temp BATON_HOME; grant/deny/expire/steal/mutex |
| Defaults | fail closed local; on_deny=reroute; no preemption; no NVML; no daemon |

**Not required for stampede-proof:** dashboard panels, weights beyond a field on the claim, queue wait, sticky run-level leases, remote multi-host coordination beyond separate host keys, thermal sensors.

### Later refinements (explicitly after v1 proves itself)

- Project/run weights + wait queue  
- Sticky per-run profile lease (warm model across tasks)  
- Soft NVML temperature / VRAM used as conservative gates  
- Doctor enforcement of "only primary stack listening"  
- Integration with owner-priority / idle saturation policy from infra.md  
- Multi-GPU host maps  
- Preemption (almost certainly never — only if operator demands)

---

## Concrete data shapes

### Claim record (`claims/<claim_id>.json`)

```json
{
  "claim_id": "c_20260801T120000Z_a1b2",
  "host": "gpu-host-a",
  "stack": "lm-studio",
  "load_profile": "model-large",
  "vram_gb": 17,
  "class": "broad",
  "run_id": "go-2026-08-01T12-00-00",
  "project": "my-dashboard",
  "weight": 100,
  "holder_pid": 18432,
  "holder_started_at": "2026-08-01T11:59:50Z",
  "holder_name": "pwsh",
  "acquired_at": "2026-08-01T12:00:00Z",
  "renewed_at": "2026-08-01T12:00:20Z",
  "expires_at": "2026-08-01T12:00:50Z",
  "ttl_sec": 30
}
```

### Acquire request (in-process)

```json
{
  "host": "gpu-host-a",
  "stack": "lm-studio",
  "load_profile": "model-large",
  "run_id": "go-...",
  "project": "my-dashboard",
  "weight": 100,
  "on_deny": "reroute"
}
```

### Acquire result

```json
{
  "granted": false,
  "reason": "profile_conflict",
  "held_by": [
    { "run_id": "go-other", "load_profile": "other-20b", "expires_at": "..." }
  ],
  "action_hint": "reroute"
}
```

or

```json
{
  "granted": true,
  "claim_id": "c_...",
  "expires_at": "...",
  "renew_every_sec": 10
}
```

### Integration point (conceptual)

```
Select-Capability(...) → candidate
if candidate.cost_tier == local:
    r = Acquire-LocalResource(candidate → host/stack/profile, run context)
    if not r.granted:
        journal local_denied
        Select-Capability(..., ExcludeLocalProfiles / ExcludeWorkers) → substitute
        if no substitute: fail task (or queue if configured)
    else:
        try: Invoke-...
        finally: Release-LocalResource(claim_id)  # renew loop only if call is long
```

For short HTTP calls, **acquire → invoke → release** without a background renew thread is enough if TTL > worst-case local latency (set TTL 60–120s for slow local gens, or renew in a nested progress callback if one exists). Prefer: TTL ≥ 2× p99 local latency, renew only if invoke API supports cooperative wait.

---

## Placement in the existing control plane

```
┌─────────────────────────────────────────────────────────┐
│  Routing (capability, cost tier, learning)              │
│  Usage Governor (API quota / lockout / conserve)        │
│  Saturation (spend free/pre-paid first)                 │
│  ★ Local Resource Governor (hardware / load profile)    │
│  Dispatch + token telemetry + journal                   │
└─────────────────────────────────────────────────────────┘
```

LRG runs **after** a local candidate is chosen (or as a filter that can demote/exclude local rows before final pick). Cleanest chokepoint: same family as usage route-around — **one place every local invoke must pass**.

Does **not** replace d043 config discipline; it **enforces** it when two runs ignore the comment in `fleet.yaml`.

---

## v1 scope (build list)

Exact first ship:

1. Lease store + named mutex + TTL/PID reclaim  
2. Host/stack/profile admission rules (exclusive stack, capacity sum, same-profile inflight cap)  
3. Acquire/Release helpers used by local dispatch path  
4. Default **reroute** with journaled `local_denied`  
5. `status` + `doctor` + `release-stale` CLI  
6. Hermetic test suite  
7. Seed profiles for gpu-host-a matching live pins (`model-large`, `model-small`); map `lm-studio` / `lm-studio-small` rows  

Success criterion: two concurrent runs cannot both hold incompatible local profiles; killing a holder frees the slot within one TTL; governor down ⇒ local denied, paid/free still work.

---

## Deliberately excluded

| Excluded | Why |
|---|---|
| Always-on GPU supervisor daemon | Operational weight; mutex+files suffice |
| Live NVML / thermal control loop | Unreliable day-1; advisory later |
| Preemption of in-flight local work | Surprising; not needed for one operator |
| Weighted fair GPU-second scheduling | Overkill; priority queue later if needed |
| Transparent silent re-route without journal | Hides cost/quality shift |
| Fail-open local when governor broken | Recreates the stampede |
| Per-provider-row locks only | Misses multi-row same-server thrash |
| Dashboard / cockpit UI | Commodity; CLI status is enough |
| Auto start/stop of LM Studio / Ollama | Ceremony; d043 stays registry-level |
| Cross-machine distributed lock for gpu-host-b | Separate host key; each box owns its store (remote dispatch acquires against remote host's policy only if we add RPC later — not v1) |
| Sticky multi-task model residency | Optimization, not safety |
| Integration with usage conserve_mode | Different resource; optional later bias |

---

## Tradeoff summary

| Choice | Gain | Cost |
|---|---|---|
| Mutex + heartbeat files | Crash-safe, inspectable, no daemon | ~30–120s worst-case wait after hard kill before reclaim |
| Load profile unit | Stops model thrash + dual-stack | Requires declared footprints |
| Fail closed local | Prevents stampede | Local work may re-route to paid when governor glitches |
| No preemption | Predictable | High-priority run may wait one inference |
| Declared not sensed | Deterministic, fast | Operator must keep VRAM numbers honest |
| Re-route default | Runs make progress | Cost/quality change — mitigated by mandatory visibility |

---

## Open points for implementer (non-blocking)

1. Exact mutex name scope (`Global\` needs SeCreateGlobalPrivilege in some locked-down setups) — fall back to `Local\BatonLocalResource` if Global fails; document.  
2. Whether ensemble fan-out of N local providers is N acquires or one multi-profile acquire — v1: **N serial acquires**; ensemble of many locals on one GPU is inherently limited.  
3. TTL default: start **60s**, renew every 20s if a renew loop is trivial; tune after measuring p99 local latency on gpu-host-a.

---

## Success definition (for a later build PR)

- Concurrent process A holds `model-large`; process B requesting a conflicting broad profile is denied and re-routes or waits — **never** double-loads.  
- Process A killed → claim free within TTL without manual file delete.  
- `ollama-local` cannot acquire while `lm-studio` claims exist on `gpu-host-a`.  
- Governor store deleted → local denied; codex/claude still dispatch.  
- No new dashboard; one CLI status page is enough for the operator.
