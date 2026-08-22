# Dark factory, prompt cache, and worktree concurrency — Baton + Grimdex

**Date:** 2026-08-22  
**Status:** APPROVED — implementation slice 1 in `feat/maestro-front-door-slice1`  
**Sources:** Cole Medin dark factory transcript, token-saver skill, Nate Jones / GLM cache transcript, Chris Noring systems talk, existing Maestro + fleet-go harness

---

## Problem

Kevin wants Level 4 “dark factory” throughput (spec in → shipped code out) without:

- Destroying provider **prompt cache** by cold-starting agents or switching models mid-thread
- Becoming the bottleneck on planning/validation (Level 3) forever
- Losing decisions that live only in conversation history

Baton already has worktrees, gates, Maestro scheduling, and prompt pool evolution. This spec locks how external dark-factory patterns map onto **Baton (execution)**, **Grimdex (rules)**, and **Grimlore (context)**.

---

## Autonomy levels (Dan Shapiro framing)

| Level | Baton mapping today |
|---|---|
| 0–2 | Manual / pair — Cursor, Claude Code, direct `/baton:codex` |
| 3 | **`baton go --execute`** — Conductor plans; Kevin validates; worktree isolated |
| 4 | **Maestro + overnight jobs + gates** — admit/fire without Kevin in loop; choices queue for A/B/C |
| 5 | Full dark factory — issue → merge → deploy with hold-out validation (partial; deploy out of scope) |

Target for 2026-08: solid **Level 4** on multiple repos concurrently via Maestro + worktrees + cache-aware sessions.

---

## Architecture map

```
Kevin / GitHub issue / choices answer
        ↓
   Conductor (shape DAG, handoff if model switch)
        ↓
   Maestro (admit, parallel cap, session registry, cache policy)
        ↓
   fleet-go OR Herdr pane (stable session per project when HERDR=1)
        ↓
   worktree (New-RunWorktree) — concurrent labor
        ↓
   verification + hold-out (builder blind) + acceptance gate (reviewer fresh)
        ↓
   archive branch / PR
```

### Cole Medin dark factory components → Baton

| Cole component | Baton equivalent |
|---|---|
| GitHub issue workflow | Maestro jobs + `seed-overnight-choices` + future GitHub webhook |
| 30 min cron driver | `maestro-watch.sh` → reconcile → admit → fire |
| Builder / validator split | fleet labor + **hold-out suite** + acceptance gate |
| mission.md triage | choices queue + project registry blurbs |
| factory rules vs global rules | Grimdex standards + repo `AGENTS.md` |
| blue/green deploy | **Out of scope** — PR archive only |
| headless agents | fleet providers + optional `maestro-herdr.ps1` |

---

## Prompt cache — four buckets

1. **Model** — which weights answer (Anthropic, OpenAI, GLM, ox-alpha…)
2. **Harness** — CLI/IDE tools, hooks, MCP (Codex, Claude Code, Herdr pane)
3. **Project context** — files: Grimdex rules, AGENTS.md, skills, tests (portable)
4. **Conversation** — ephemeral thread (expensive to move; not portable across providers)

### Rules (Grimdex policy → `universal/playbooks/prompt-cache.md`)

1. **Finish substantial work on the model you started with.** Late provider switch re-reads history without old cache (often *more* expensive).
2. **Prefer file handoffs over transcript paste** when switching model or worker (`maestro-session-lib` handoff template).
3. **Stable prefix, delta suffix** — shared instructions byte-identical; task-specific content after.
4. **One warm session per (project × primary worker)** when using Herdr (`HERDR=1` + session registry).
5. **Parallel cap limits cold starts** — Maestro `MaxParallel` is also a cache-preservation dial.
6. **Decisions live in files** — Grimdex decisions, run ledger, handoff — never only in chat.

### Baton layers

| Layer | Mechanism |
|---|---|
| Provider cache | Session registry + Herdr; avoid mid-thread model switch |
| Prompt evolution | `$BATON_HOME/prompts/pool/` + `/baton:optimize-prompt` |
| Context selection | **token-saver** tools (`context-select`, `state-delta` capabilities) |
| Metering | ship-report `cache_read` / `cache_creation`; heartbeat probes |

---

## Worktree concurrency

Pattern (unchanged, canonical):

```
<repo>/                          ← Kevin tree untouched
<repo>/../.baton-worktrees/<id>/ ← labor
baton/run-<id>                   ← review branch
```

| Scope | Mechanism |
|---|---|
| Cross-project overnight | Maestro: one admitted job per project, parallel cap 8 |
| Within one spec | Conductor DAG → `/baton:code-parallel` waves |
| Cheap worker | Separate worktree + 6-line handoff file |
| Review | Fresh gate context (no builder cache bias) |

---

## Hold-out validation (Level 4 reliability spike)

Builder must **not** read `.baton/holdout/` (excluded from labor prompts and `allowed_paths`).

Validator / hold-out runner reads frozen scenarios from **base commit** (`git show <base>:.baton/holdout/manifest.json`), same immutability model as `.baton/verification.json`.

See `scripts/holdout-lib.ps1` and `references/holdout/README.md`.

---

## Grimdex / Grimlore routing

| Content | Home |
|---|---|
| Cache policy, handoff template, model-switch rules | Grimdex `universal/playbooks/prompt-cache.md` |
| token-saver skill | Grimdex `universal/skills/token-saver/` |
| Mission, audience, out-of-scope | Grimlore host cards |
| Session registry, handoffs, Maestro ticks | Baton `$BATON_HOME/maestro/` |
| Lessons from cache waste | Grimdex lessons via `/consolidate-lessons` |

---

## Implementation slice 1 (this branch)

- [x] This spec
- [x] `tools/token_saver/` + `references/tools.yaml` rows
- [x] `scripts/fleet-context-select.ps1`, `fleet-state-delta.ps1`
- [x] `scripts/maestro-session-lib.ps1` + handoff + Herdr registry
- [x] `scripts/holdout-lib.ps1` + example manifest
- [x] `scripts/maestro-fold-stale.ps1` + reconcile extensions
- [x] Grimdex skill + playbook port

---

## Revisit if

- Herdr exposes stable session IDs per pane for cache metrics
- `tools/invoke.py` lands — wire token-saver through unified runner
- Kevin approves autonomous merge + blue/green deploy track
