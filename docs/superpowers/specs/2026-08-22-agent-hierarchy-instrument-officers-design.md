# Agent hierarchy, instrument registry, and factory officers

**Date:** 2026-08-22  
**Status:** approved by Kevin (session) — implements `baton-d133`  
**Extends:** `baton-d108`, `baton-d119`, `baton-d124`, Local Resource Governor design (`2026-08-01-local-resource-governor-design.md`), d043 (one model-serving process per box)  
**Does not reopen:** Maestro stays deterministic for admission; no merge without Kevin; Ox privacy / no private Grimlore to OpenRouter.

## 1. Picture

```
Kevin
  └─ Mouth / Composer ………… Ox Alpha (converse, free)
        └─ Maestro ………………… deterministic code only (admit / fire)
              ├─ Scheduler sidecar ………… windows, residue, Fable ≤1/h, excess_capacity
              ├─ (queries) Systems agent … hardware inventory / placement advice
              ├─ (queries) VRAM officer … local inference claims (may briefly queue)
              └─ Conductor(s) ………… Ox Alpha (thin)
                    ├─ Efficiency Officer sidecar … never block labor
                    └─ Orchestrator(s) ………… Opus (1+ per project; N under load)
                          └─ Instruments ………… many concurrent
                                ├─ LM fleet (Ox diff_apply, Codex/Grok/Kiro/Cursor agentic, local LMS)
                                └─ tools.yaml (Docling, OCR, WTM, scraper, …)
```

**Agent** = umbrella term for anything doing work. Prefer role names (Maestro / Conductor / Orchestrator / Instrument / Officer) in routing and docs.

## 2. Terminology lock

| Role | Spawns / owns | Default LM / impl |
|---|---|---|
| Maestro | Admits jobs; fires Conductor/`fleet-go`; never chatty | Code |
| Conductor | Plans goal → task DAG; spins Orchestrator(s) | Ox Alpha |
| Orchestrator | Disjoint claims; routes instruments; gates | Opus |
| Instrument | Finishes one capability-scoped task | Fleet + tools |
| Officer / Systems | Standing advisors/enforcers (see §4) | Mixed |

All jobs **enter through Maestro**. Scheduler shapes *eligibility*; Maestro still admits.

## 3. Pre-defined instruments

### 3.1 Registry row (conceptual ABI)

Each instrument declares:

- `capability` (e.g. `code-gen`, `ocr`, `security-sweep`, `youtube-transcript`)
- `host` affinity (droid / firefly / Pi / cloud)
- tool paths + invoke recipe (`tools.yaml` and/or fleet provider)
- **init brief** (instructions materialized at spawn)
- model allow / deny list
- before / during / after **hooks** (deterministic)
- verify recipe

Orchestrators select by capability. They do not re-derive “how to download YouTube captions” every run.

### 3.2 Coding instrument + language profiles

**One** coding instrument class. Language is a **profile**, not a separate agent:

`python` | `pwsh` | `typescript` | `javascript` | `nodejs` | `react` | `html-css`

Each profile is a **lean** payload: known pitfalls, verify commands, watch-outs. Efficiency Officer regularly reviews profiles (Grimdex-shaped: aggressively maintained, aggressively small). Bloat is a defect.

### 3.3 Tool / domain instruments (initial catalog)

| Instrument | Kind | Notes |
|---|---|---|
| security-researcher | scheduled LM + scanners | See §5 |
| research | LM + fetch | Cite; no private Grimlore → Ox |
| scheduler | code (Maestro sidecar) | §4 |
| coding (+ profiles) | LM agentic / diff_apply | §3.2 |
| doc-convert (Docling) | tool | tools.yaml |
| web-scraper | tool (+ LM extract) | |
| youtube-transcript | tool | research-instruments runner |
| av-transcribe | tool | Prefer NPU when Systems says so |
| ocr | tool | |
| pi-ops | tool + SSH | Host-bound |
| n8n-ops | tool + SSH | Host-bound |
| efficiency-officer | Conductor sidecar | §4 |
| (future) | … | Add via registry, not ad-hoc agents |

## 4. Standing officers

### 4.1 Scheduler (Maestro sidecar)

- Owns quota calendars: weekly/monthly resets, nested 5-hour windows, Fable ≤1/hour.
- Tags and releases `excess_capacity` jobs only when residue math allows.
- Prevents “burn Fable in three hours” by refusing grind on scarce seats.
- Does **not** admit; injects eligibility into Maestro’s queue.

### 4.2 Efficiency Officer (Conductor sidecar)

- Process optimizer for the active goal: cheaper seats, shorter scopes, prompt reuse/caching, worktree fan-out + fold.
- **Never blocks labor** — advise, throttle, reshape.
- **Anti-overengineering:** if a “save” costs more coordination than it saves, kill it.
- Token-watch is a duty under this officer, not a separate agent.
- Maintains / reviews lean language profiles for the coding instrument.

### 4.3 VRAM officer (Maestro-adjacent; not a “grunt”)

Agent face of Local Resource Governor + d043:

| Duty | Behavior |
|---|---|
| Inventory | Loaded model(s) on firefly / droid / Pi |
| Claim | Exclusive “1× large” or shared “N× small” before local dispatch |
| Serialize | Second waiter queues or fails over to Ox/cloud — no thrash-load |
| Prefer warm | Keep model if next jobs fit |
| Release | End-of-lane + idle TTL unload |

**May briefly block** local dispatch. A short queue beats unloading a 30B model five times an hour. Rank is **officer** (gates/seats), not grunt (file labor).

### 4.4 Systems agent (inventory / advisory)

Catalogs local hardware and edge:

- GPU(s), VRAM, NPU (e.g. Speech-to-text on NPU so firefly GPU stays free for coding models)
- CPU/RAM, disk, Tailscale reachability
- Pi / n8n / edge roles

**Recommends** placement; does not hold the VRAM mutex (VRAM officer does). Feeds health canary / doctor.

## 5. Security researcher

| Cadence | Seat | Scope |
|---|---|---|
| Nightly / frequent | Ox Alpha, local Qwen, other free | Projects touched since last run; cheap scanners |
| Infrequent / deep | **Opus** primary; Qwen via Kiro/Cursor/agy when available | Adversarial interpretation; prioritize findings |
| Weekly | Free/local default; Opus on signal or excess_capacity | All GitHub remotes (including old) |

**Do not** seat deep security on Fable or GPT-5.6 Sol — guardrails make them uniquely bad at adversarial / “hacking”-adjacent review. Revisit if vendor policy changes.

Sliding scale:

- **Hot** — touched since last run → nightly  
- **Warm** — active + recent clean → weekly  
- **Cold** — untouched N weeks + prior clean → monthly / excess_capacity only  

Scanners = deterministic spine; LM interprets. No private Grimlore into Ox.

## 6. Excess capacity

Steady state = cheapest continuous labor. **Residue** at the end of a paid window is a different budget:

| Spend menu | Examples |
|---|---|
| Adversarial review | Recent coded slices |
| Ideation | Features, architecture options |
| Deep security | Full GitHub set |
| High-lens review | Plan / sprint once-overs skipped in economy mode |

Nested constraint rule: if weekly residue remains but the current 5h window cannot burn it, Scheduler **pulls work into an earlier window** next cycle — not a dump into a saturated window.

## 7. Cross-platform / reliability binding

Officers and instruments inherit the 2026-08-22 control-plane fixes:

- Dead `pwsh` → `_pwsh-guard` + health canary (fail-loud)
- Diff-apply empty context → loud fail when `allowed_paths` all outside worktree
- Parallel `fleet-go` → unique run IDs (ms + hex)
- Split fleets → Ox on home + overnight; locals (droid LMS + firefly workhorse) enabled for concurrent grunt under VRAM officer

## 8. Implementation sketch (not authorized as a single mega-PR)

Ordered wedges:

1. Document registry schema next to `tools.yaml` + fleet capabilities  
2. Scheduler eligibility hooks into Maestro job states (`queued` / `waiting-quota` / `excess_capacity`)  
3. VRAM officer claims wired at local `Select-Capability` / dispatch (implement LRG)  
4. Systems inventory file under `$BATON_HOME` (box-private) + doctor probes  
5. Security instrument recipe + sliding-scale state file  
6. Efficiency Officer as Conductor post-plan / pre-dispatch advisor  
7. Language profile dir (lean markdown) + Efficiency Officer review loop  

## 9. Non-goals

- Replacing Maestro with an LM  
- Per-language agent processes  
- Efficiency Officer as an admit gate  
- Auto-merge of any instrument output  
- Pasting Grimlore bodies into Ox / OpenRouter for security or research  
