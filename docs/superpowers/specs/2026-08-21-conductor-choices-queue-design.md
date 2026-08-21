# Conductor Choices Queue — persistent needs-you cards

**Date:** 2026-08-21  
**Status:** design approved — awaiting implementation plan  
**Audience:** agents implementing the Choices first slice; Maestro/Conductor Mouths presenting overnight decisions  
**Extends:** `baton-d111` (one front door), Maestro job statuses (`held` exists but is coarser), Slice 1 dashboard “needs-you” (viewer only; not this store)  
**Does not reopen:** deterministic Maestro; four-layer seating; auto-route (Kevin says project + task)

---

## Problem

Overnight (and daytime) factory work surfaces **blocking product choices** — A/B/C forks, publish/push/sign-off — across many projects. Today they arrive as chat dumps. Kevin cannot cycle them cleanly, project-by-project. Conductors have no durable place to park a question; Orchestrators either stall or invent parallel markdown.

## Goal

A **factory-level Choices queue**: Orchestrators draft, Conductors admit, Kevin answers one subject at a time (chat now; Portal later). Soft-park only the blocked slice. First shippable slice: **schema + `$BATON_HOME` store + thin CLI** (`brief` / `next` / `answer` / `list`).

## Non-goals (first slice)

- Portal / dashboard UI (preferred answering surface **later**)
- Auto-unblock wiring into `fleet-go` / Maestro fire
- Append-only audit JSONL (optional **v1.1** if file history proves insufficient)
- Grimdex auto-promotion of answers (record on card first; promote after review)
- Fable; merge-to-master policy changes

---

## Locked decisions (brainstorm)

| # | Decision |
|---|---|
| Surface | **Hybrid:** chat primary now; same store for future Portal |
| Park | **Soft park:** blocked slice waits; other project work continues |
| Idle | If no unblocked work → light research / “what else to build” (docs only) |
| Authorship | **Orchestrator drafts → Conductor admits**; Kevin only sees admitted |
| Cycle | **One project at a time** until that project’s admitted queue is clear |
| Project order | **Priority then age** (P0→P2, then older first) |
| Overnight | One **brief** writeup (all projects), then **auto-start** first card of top project |
| Store | `$BATON_HOME/choices/` — coordinator above project folders |
| Persistence | **One JSON file per choice**; audit log later if needed |
| First slice depth | Store + thin CLI (not files-only; not full auto-unblock) |

Mental model: Baton runs **a level up** from project folders (e.g. Dev root). Work happens inside project dirs; coordinator state (choices, maestro jobs, overnight) lives under `$BATON_HOME`.

---

## 1. Store & state machine

**Path:** `$BATON_HOME/choices/` (default `~/.baton/choices/`).

**Files:** `ch-<id>.json` — one choice per file. Cursor: `_cursor.json` (not a choice).

**Status enum (closed — unknown = invalid):**

```
draft → admitted → answered | rejected
                 ↘ superseded
```

| Status | Who writes | Visible in Kevin’s cycle? |
|---|---|---|
| `draft` | Orchestrator (via lib/CLI) | No |
| `admitted` | Conductor | Yes |
| `answered` | CLI after Kevin’s pick | Done |
| `rejected` | Conductor | No (clears block without answer) |
| `superseded` | Conductor replacing a card | No |

**Soft-park:** `blocks` names the slice/worktree/goal that must not burn tokens until terminal status (`answered` | `rejected` | `superseded`). Project Maestro job stays `running` — do **not** force whole-job `held` for a single choice.

**Idle fallback:** Conductor with zero unblocked runnable work → research briefs only; never invent product code that depends on unanswered admitted choices; never fake an `answered` card.

---

## 2. Card schema (`schema_version: 1`)

Required:

| Field | Notes |
|---|---|
| `schema_version` | Integer; start `1`. CLI refuses unknown versions. |
| `id` | Matches filename stem (`ch-…`) |
| `status` | Enum above |
| `project` | Registry slug (`canvas-toolchain`, `bookprofile`, …) |
| `priority` | `P0` \| `P1` \| `P2` — set/confirmed on **admit**; drafts may omit (default `P1` on admit) |
| `title` | One line |
| `question` | Short body |
| `options` | Array ≥2 of `{ id, label, summary }` |
| `recommendation` | `{ option_id, why }` |
| `evidence` | Array of paths/URLs (reports, specs, PRs) |
| `created_at` / `updated_at` | ISO-8601 |
| `admitted_at` / `answered_at` | Optional until those transitions |

Optional:

| Field | Notes |
|---|---|
| `blocks` | Slice / worktree / goal id for soft-park |
| `answer` | On answered: `{ option_id? , free_text? , note? }` — at least one of option_id or free_text |
| `supersedes` / `superseded_by` | ids when replacing |

**Forbidden (drift):**

- Parallel human queues (`choices.md`, Mouth-only lists without files)
- Freeform `status` strings
- Options without stable `id`
- Chat “answers” that never call `baton choices answer`
- Hand-editing status without going through the shared lib (discouraged; lib is source of truth)

**Deliberate change:** new behavior → bump `schema_version` or a Grimdex/Baton decision — not silent field invention.

---

## 3. Cursor & cycle

`_cursor.json` (example shape):

```json
{
  "schema_version": 1,
  "active_project": "canvas-toolchain",
  "current_id": "ch-…",
  "project_order": ["canvas-toolchain", "bookprofile", "atomicforge"]
}
```

**Rules:**

1. `brief` builds project order: among projects with ≥1 `admitted`, sort by best (lowest) priority on any admitted card, then oldest `admitted_at`.
2. Writeup: one turn, per project — blocked work, choices, reasoning/recommendation.
3. Auto-start: set cursor to first project; present first admitted card (oldest within same priority).
4. `next` / after `answer`: stay on project until no `admitted` remain; then advance to next project in order.
5. Explicit “skip to \<project\>” (chat or later flag) may jump; still clear that project before leaving unless Kevin jumps again.

---

## 4. CLI (first slice)

All mutations go through a shared lib used by these verbs (PowerShell and/or existing `baton` verb surface — plan picks the seam; behavior is fixed here):

| Verb | Behavior |
|---|---|
| `baton choices brief` | Print overnight-style writeup; refresh `project_order`; reset cursor to first project’s first card |
| `baton choices next` | Print current/next admitted card; advance cursor if current already answered |
| `baton choices answer <id> <option_id \| --text …>` | Persist `answer`, set `answered`, advance cursor |
| `baton choices list [--project] [--status]` | Inspect |
| `baton choices draft …` | Orchestrator: create `draft` |
| `baton choices admit <id> [--priority P0]` | Conductor: `draft` → `admitted` |
| `baton choices reject <id>` | Terminal without Kevin answer; clears soft-park |

**Chat contract:** Mouth runs `brief` when presenting a multi-project dump, then presents `next`. Kevin’s reply maps to `answer`. No card in chat without a `ch-` id.

**Exit honesty:** unknown schema/status → non-zero. Bad option id → refuse. Empty queue → plain “none admitted.”

---

## 5. Layers

| Layer | Role |
|---|---|
| **Maestro** | No LLM. Does not author choices. May later read admitted count for status lines only. |
| **Conductor** | Admits/rejects/supersedes; owns priority and Kevin-facing cycle; Mouth presents cards |
| **Orchestrator** | Drafts with evidence and real options after instrument work |
| **Instrument** | Never writes choices directly |

---

## 6. Failure modes & drift

| Risk | Guard |
|---|---|
| Status invention | Closed enum; refuse unknown |
| Schema creep in chat | `schema_version`; lib-only writes |
| Duplicate cards | Conductor supersede/merge on admit; same `blocks` + similar title → prefer one admitted |
| Choice spam | Drafts invisible until admit |
| Whole factory freeze | Soft-park only; idle research instead of hard idle |
| Lost answers | Answer only via CLI/lib writing the file |
| Concept drift vs bad drift | If direction should change, **reason + bump schema/decision** — do not silently diverge folders |

---

## 7. Testing (first slice)

Pure lib tests (no live LLM):

1. Admit ordering: P0 before P1; same priority → older `admitted_at` first  
2. Project-at-a-time cursor: does not leave project while admitted remain  
3. Schema refuse: bad status / bad version  
4. Answer persistence: option id and `--text` paths  
5. `brief` project_order matches priority-then-age rule  

---

## 8. Later (explicitly out of first slice)

- Portal needs-you UI reading the same store  
- Auto-unblock: answering notifies waiting Orchestrator / clears claim  
- Append-only `choices-events.jsonl`  
- Grimdex promotion of answered cards  
- Skip/defer verbs if chat proves we need them  

---

## Success criteria

1. Overnight multi-project dump → one `brief` → auto first card → Kevin clears one project fully before the next.  
2. Every Kevin-facing question has a `ch-*.json`; chat cites the id.  
3. Orchestrator ambiguity becomes a **draft**, not a Kevin interrupt, until Conductor admits.  
4. No parallel markdown choice queues in overnight reports once CLI exists.
