# Nate Jones — prompt cache, worktrees, and multi-agent dispatch (deep dive)

**Date:** 2026-08-22  
**Status:** reference — maps Nate Jones / token-saver teaching to Baton + Grimdex  
**Sources:** `_Stop Paying $200 For Work An $18 Model Can Do Inside Claude Code And Codex..docx` (Nate Jones, Aug 2026), token-saver skill, Baton `feat/maestro-front-door-slice1` implementation  
**Companion spec:** `2026-08-22-dark-factory-cache-worktrees-design.md`  
**Grimdex policy:** `Ryfter/Grimdex` → `universal/playbooks/prompt-cache.md` (decision `baton-d132`)

---

## Why this doc exists

Kevin asked for a **deep dive** on what Nate talked about: how to create worktrees correctly, spawn multiple agents without wasting context, and how **provider prompt cache** actually works so you are not re-paying for the same prefix on every turn.

The economic punchline from Nate's own measurement: on heavy Codex/Claude days, **~96% of token volume was reused input** — system instructions, tool defs, file context, and conversation history. That means **cache hygiene is not optional**; it is most of the bill.

---

## Part 1 — The four buckets (do not mix these up)

Nate separates four things people conflate when they say "switch models":

| Bucket | What it is | Portable? | Cache behavior |
|---|---|---|---|
| **1. Model** | Weights/provider (Claude, Codex, GLM, ox-alpha…) | No | Cache is **per provider + per session** |
| **2. Harness** | Claude Code, Codex CLI, Cursor, Herdr pane, Baton `fleet-go` | Partially | Tools, hooks, MCP, permissions — **your setup** |
| **3. Project context** | Files: `AGENTS.md`, Grimdex rules, skills, tests, docs | **Yes** | Re-read cheap if small; **stable prefix** helps cache |
| **4. Conversation** | Ephemeral thread — asks, reads, corrections, hidden state | **No** | Most expensive to move; **not portable across providers** |

**Critical insight:** Changing the model does **not** move all four equally. Files survive; conversation mostly does not.

### Rule of thumb #1 (Nate)

> **Start substantial work on the model you expect to finish it.**

Building 40 turns of working history with Anthropic and then switching to Z.AI/GLM in the final mile often costs **more**, not less — Anthropic docs warn the new model re-reads full history **without** old prompt caches (creation-rate billing on the prefix).

**Baton translation:** Maestro should not casually rotate providers mid-job on the same goal. Use **handoff files** + optional **cheap worker in a separate worktree** instead.

---

## Part 2 — What prompt cache actually is

### Provider prompt cache (Anthropic, OpenAI, etc.)

- Repeated **identical prefix** on subsequent API calls within a session/window → billed as **cache read** (cheap) vs **cache creation** (expensive).
- Changing **anything** in the stable prefix invalidates reuse for that block.
- Switching **provider** mid-thread → new cache namespace; old cache does not transfer.

### What is NOT cache

| Mechanism | What it does |
|---|---|
| **Baton prompt pool** (`$BATON_HOME/prompts/pool/`) | Evolves Conductor planner text (GEPA) — cross-run, not provider KV cache |
| **Grimdex / Grimlore files** | Durable context — survives any session; you pay read tokens once per cold start |
| **`.token-saver/state.json`** | Accepted-result checkpoint — avoids re-sending full transcript on follow-ups |
| **Maestro `sessions.json`** | Maps project → Herdr pane — keeps **harness session warm**, not model weights |

Baton **meters** cache via ship-report: `cache_read_input_tokens` vs `cache_creation_input_tokens`.

---

## Part 3 — Stable prefix + delta suffix

Nate + token-saver strategy #6:

1. Put **shared, byte-stable** material first: rules, repo map, tool catalog, permissions.
2. Put **new assignment** after: task, handoff, diff, change request.
3. Do **not** mutate the shared block mid-job (even whitespace changes can break reuse).

**Anti-pattern:** Pasting the entire prior conversation into a "worker" prompt — you pay creation rate on all of it and destroy cache structure.

**Correct pattern:** Six-line handoff + selected passages (`context-select`) + state delta (`state_delta.py`).

---

## Part 4 — The six-line handoff (model switch boundary)

When you **must** move work (limit hit, cheaper worker, parallel lane):

| Field | Example |
|---|---|
| **Goal** | Update 38 API calls to new field name |
| **Current state** | Branch clean; calls in `src/api/` and `tests/` |
| **Relevant files** | `src/api/client.ts`, `tests/test_client.py` |
| **Constraints** | Do not change public API surface |
| **Done when** | Old field gone; existing tests pass |
| **Checks** | `pytest tests/test_client.py`, `rg OldFieldName` |

**Baton implementation:** `scripts/maestro-session-lib.ps1` → `Format-MaestroHandoff` / `Write-MaestroHandoff`  
**Storage:** `$BATON_HOME/maestro/handoffs/<job-id>.md`  
**CLI:** `pwsh scripts/maestro-handoff.ps1 write -JobId mj-… -Goal "…"`  
**On fire:** `Expand-MaestroGoalWithHandoff` prepends handoff to Maestro goal — **no assumed parent chat history**

---

## Part 5 — Multi-agent patterns (Claude Code / Codex / Baton)

### A. Normal subagent (fresh context)

- Gets delegated task + project instructions from files.
- Does **not** get full parent conversation.
- **Good for:** narrow, bounded work (research, single file, log triage).
- **Cache:** own cold start; bounded = cheaper.

### B. Forked subagent (same model only)

- Gets **full parent conversation**.
- Can **reuse parent's prompt cache**.
- **Constraint:** fork **must use same model** as parent.
- **Good for:** parallel steps that need full thread context without re-billing prefix.
- **Bad for:** switching to GLM/ox-alpha — fork cannot help.

### C. Separate session / separate harness command (Nate's GLM pattern)

- `claude-g` launcher or `codex --profile glm` — same repo, same files, **new conversation**.
- Inherits **harness + project context**; not prior conversation.
- **Requires handoff** if mid-job continuity matters.

### D. Git worktree + agent (Baton canonical)

```
/Users/kev/Dev/MyRepo/                          ← Kevin tree (untouched)
/Users/kev/Dev/.baton-worktrees/<run-id>/       ← labor happens here
branch: baton/run-<run-id>                      ← review branch (human merges)
```

**Created by:** `New-RunWorktree` in `scripts/fleet-executor-lib.ps1`

```powershell
# Returns: worktree path, branch name, base_sha
git worktree add -b baton/run-<id> ../.baton-worktrees/<id> HEAD
```

**Why sibling `.baton-worktrees/` not inside repo?**

- Kevin's checkout stays clean and on `main`/feature branch.
- Multiple agents can labor concurrently without fighting over one working tree.
- Failover can `Restore-WorktreeTreeSnapshot` without touching Kevin's tree.

### E. Maestro cross-project parallel (overnight factory)

| Control | Purpose |
|---|---|
| `maestro-admit.ps1` | Quota-aware: one admitted job per project |
| `maestro-fire.ps1` | Fan-out up to `MaxParallel` (default 8) **disjoint projects** |
| `MaxParallel` | Also a **cache-preservation dial** — too many cold starts on same repo wastes cache |
| `maestro-fold-stale.ps1` | Frees ghost `running` slots before admit |

**Rule:** Parallel overnight = **different repos**, not eight cold agents on one repo unless intentional.

### F. Within one spec — Conductor DAG + `/baton:code-parallel`

- Topological **waves** of subtasks.
- Each subtask → **isolated worktree** (`isolation: worktree` in Agent dispatch).
- Wave 2 waits on wave 1 manifests — dependencies explicit.
- See `commands/code-parallel.md`.

### G. Herdr warm panes (`HERDR=1`)

- **One persistent pane per project** → harness session survives laptop close.
- Registry: `$BATON_HOME/maestro/sessions.json` maps `project → herdr_target`.
- `Resolve-MaestroHerdrTarget` / `Update-MaestroSessionAfterFire`.
- Complements worktrees: worktree = **where files change**; Herdr = **where conversation cache lives**.

---

## Part 6 — Which jobs go to cheap workers (GLM, ox-alpha)

Nate's routing matrix — same as Grimdex playbook:

| Send to cheap worker | Keep on strong model |
|---|---|
| Clear definition of done | Deciding what the job *is* |
| Repo has examples + tests | Hidden state / root cause |
| Bounded `allowed_paths` | Risky trade-offs |
| Handoff file, not transcript | Need full investigation thread |

**Kevin's fleet note:** Ox Alpha free tier is time-boxed — use for **volume bounded edits**, not architecture.

**Anti-pattern:** Pull entire parent transcript into GLM worker — job is too unbounded; cache savings evaporate in retries.

---

## Part 7 — Context that must live in files (not chat)

If it only exists in conversation, a model switch loses it:

| Put in files | Examples |
|---|---|
| Decisions | Grimdex `decisions/`, repo `docs/*-decisions.md` |
| Done definition | Handoff `Done when`, `.baton/verification.json` |
| Standards | Grimdex rules, `AGENTS.md`, skills |
| Accepted output | `.token-saver/state.json` via `state_delta.py save` |
| Run evidence | `$BATON_HOME/runs/<run-id>/` ledger |

**token-saver instruments (Baton):**

```powershell
# Bounded passage selection — no model call
pwsh scripts/fleet-context-select.ps1 -Request "npm OIDC decision" -Root /path/to/repo -Output /tmp/packet.txt

# Accepted result + delta only
pwsh scripts/fleet-state-delta.ps1 save -State .token-saver/state.json -AcceptedFile result.md
pwsh scripts/fleet-state-delta.ps1 packet -State .token-saver/state.json -Change "Add tests" -Output /tmp/change.txt
```

---

## Part 8 — Hold-out validation (cache bias vs correctness)

Builder accumulates bias from its own plan and tests. Cole Medin / Baton pattern:

- `.baton/holdout/manifest.json` frozen from **base commit** (`git show <base>:…`).
- Builder **must not read** `.baton/holdout/` (excluded from labor paths).
- Validator runs hold-out **fresh** — no builder cache bias.

```powershell
pwsh scripts/fleet-gate.ps1 holdout -RepoPath . -BaseSha HEAD -Worktree .
```

---

## Part 9 — Operational recipes

### Recipe 1 — Overnight fan-out (8 projects, cache-aware)

```bash
# ~/.baton/overnight/bin/maestro-watch.sh  →  maestro-tick every ~20s
# tick order: fold-stale → reconcile → admit → fire
export HERDR=1   # optional: warm panes per project
```

1. Queue jobs: one **goal per project** in `~/.baton/maestro/jobs/`.
2. Write handoff if continuing prior work: `maestro-handoff.ps1 write …`
3. Register pane: `maestro-handoff.ps1 register -Project answerbot -HerdrTarget maestro-answerbot`
4. Let admit cap parallel cold starts; do not duplicate same-project fires.

### Recipe 2 — Cheap worker on bounded edit (same repo)

1. Strong model writes **six-line handoff** (+ optional `context-select` packet).
2. `New-RunWorktree` or Maestro fire → ox-alpha/GLM in **that worktree only**.
3. Worker returns: files changed, checks run, blockers.
4. Strong model reviews diff on `baton/run-<id>` branch — **fresh gate context**.

### Recipe 3 — Same provider, parallel narrow tasks (fork or subagent)

- **Same model, need parent context:** Claude forked subagent.
- **Same model, bounded task:** normal subagent with file instructions.
- **Baton:** `/baton:code-parallel` waves with worktree isolation.

### Recipe 4 — Never do this

| Anti-pattern | Why |
|---|---|
| Switch Anthropic → OpenRouter mid-thread on same task | Re-bills prefix at creation; slower |
| 8× `fleet-go` cold start on one repo simultaneously | Destroys cache; merge conflicts |
| Store decisions only in Cursor chat | Lost on next agent / model |
| Paste 200k transcript into worker | Unbounded; retries multiply cost |
| Labor in Kevin's main checkout | Blocks human; dirty tree risk |

---

## Part 10 — File map (where things live)

| Artifact | Path |
|---|---|
| Session registry | `~/.baton/maestro/sessions.json` |
| Handoffs | `~/.baton/maestro/handoffs/<job-id>.md` |
| Maestro jobs | `~/.baton/maestro/jobs/mj-*.json` |
| Worktrees | `<repo-parent>/.baton-worktrees/<run-id>/` |
| Accepted result state | `<worktree>/.token-saver/state.json` |
| Cache policy | Grimdex `universal/playbooks/prompt-cache.md` |
| token-saver skill | Grimdex `universal/skills/token-saver/` |
| Design spec | `docs/superpowers/specs/2026-08-22-dark-factory-cache-worktrees-design.md` |
| This deep dive | `docs/superpowers/specs/2026-08-22-nate-jones-cache-worktrees-deep-dive.md` |

---

## Part 11 — Measuring whether you actually saved money

Nate: compare **fully loaded cost** — planning + worker + review + retries.

Baton ship-report aggregates per run:

- `cache_read_total` vs cache creation
- Provider mix
- Retry/failover counts

**Success criterion:** Same acceptance rate, **lower total tokens** or dollars — not "cheaper model per call" with 3× retries.

---

## Summary card (print this)

```
FOUR BUCKETS:  model | harness | files | conversation
               only files + handoffs survive provider switches

CACHE:         stable prefix first, delta after
               finish on the model you started
               one warm pane/project (Herdr) when sequential

WORKTREES:     Kevin tree clean → .baton-worktrees/<id> → baton/run-<id>
PARALLEL:      cross-project = Maestro | in-project = code-parallel waves
HANDOFF:       goal, state, files, constraints, done, checks

CHEAP WORKER:  bounded + tests + handoff — NOT root-cause + NOT full transcript
MEASURE:       cache_read vs creation in ship-report; count all model calls
```

---

## Trust

Synthesized from Nate Jones transcript (Aug 2026), token-saver skill, and Baton implementation on `feat/maestro-front-door-slice1` @ `b887aaf`. Operational commands verified against repo scripts; provider pricing details change — always read current provider docs.
