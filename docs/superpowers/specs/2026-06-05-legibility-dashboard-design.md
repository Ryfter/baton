# Slice 1 — Legibility dashboard + autonomy

**Status:** spec (approved concept 2026-06-05) · **Parent:** [`2026-06-05-fleet-conductor-concept.md`](2026-06-05-fleet-conductor-concept.md)
**Decisions:** d018 (conductor / call-outs), d019 (web dashboard primary surface)

The first buildable slice. It attacks **both** north-star pains directly and depends on
**nothing external** — only what already exists in this repo (the FastAPI dashboard, the fleet,
OTel cost export, the PostToolUse hook, and Claude Code's status line). No GitHub, no ruflo, no
sprites.

---

## 1. Goal & success criteria

**Goal:** kick off fleet work and, at any moment, see in plain English what each agent is doing
and why — while pressing "1/2" far less.

Done when:

1. The dashboard shows a **runs gutter** (narrow, 2–3-line cards) + **detail pane** + **global
   strip**, live-updating.
2. Each run's detail reads as **plain English** ("what + why"), not raw tool logs.
3. A run that needs a human decision shows `⏳ needs you`; the user answers inline and the run
   un-blocks — **the needs-you queue**.
4. A **permission allowlist** is in place so routine safe tool calls stop prompting.
5. The whole thing runs **offline** (preserves d015 self-contained dashboard).

**Explicitly out of scope (deferred to later sub-projects):** GitHub/Agent HQ coordination,
ruflo execution backend, the adversarial-dev quality loop, pixel sprites, VS Code/Kiro/Copilot
renderers, the `/idea` front door.

## 2. The two pains, mapped to two concrete deliverables

- **Autonomy** = (a) a curated **permission allowlist** (`permissions.allow` in settings) that
  auto-approves read-only / safe-mutation tool calls — the instant win that kills most 1/2
  prompts; plus (b) the **needs-you queue** for dispatched runs, so fleet/subagent decisions are
  *parked* (non-blocking) instead of halting on a modal prompt. (We control the dispatch loop
  for fleet runs; we are **not** intercepting the top-level Claude session's own prompts in this
  slice — the allowlist covers that side.)
- **Legibility** = the **runs dashboard** fed by a neutral state store, narrated in plain
  English.

## 3. Architecture — feed + producers + renderer

```
 PRODUCERS                         FEED (neutral state)            RENDERER
 ─────────                         ───────────────────             ────────
 PostToolUse hook  ──append──▶  ~/.claude/runs/<id>/events.jsonl   FastAPI dashboard
 status-line script ─update─▶   ~/.claude/runs/<id>/run.json       ├─ gutter  (run cards)
 OTel exporter     ──cost───▶   ~/.claude/runs/index.json (global) ├─ detail  (timeline)
 agent intent line ─append─▶    ~/.claude/runs/<id>/answer.txt     └─ global strip (footer)
                                  (needs-you answer channel)
```

The **legibility feed** is the single source of truth and the neutral contract every future
surface renders (d019). Producers write it; the dashboard only reads it (plus one write: posting
an answer).

### 3.1 What a "run" is

A **run = one agent × one task × one worktree.** "Codex running 2, 3 queued" → 2 active run
records + 3 queued. Runs carry an optional `project` and `job` for grouping/filtering.

### 3.2 Data model

**`run.json`** (per run — the status-bar + detail header):
```json
{
  "id": "run_2026-06-05_auth-rewrite",
  "name": "auth-rewrite",
  "model": "claude-opus-4-8", "reasoning": "high",
  "project": "coding-agent-orchestrator",
  "tree": "master", "worktree": false,
  "status": "running",            // running | needs-you | idle | done | failed | queued
  "context_pct": 10,
  "cost_usd": 12.40, "tokens_in": 41000, "tokens_out": 7000,
  "files_touched": ["auth.ts", "validator.ts", "auth.test.ts"],
  "current_step": "implement grace window",
  "parked_question": null,        // string when status == needs-you
  "started_at": "2026-06-05T20:14:00Z", "updated_at": "2026-06-05T20:31:00Z"
}
```

**`events.jsonl`** (per run — the plain-English timeline, append-only):
```json
{"ts":"…","kind":"action","what":"read auth middleware + 3 callers","why":"map blast radius before editing","status":"done"}
{"ts":"…","kind":"action","what":"wrote a failing rotation test","why":"lock the contract first","status":"done"}
{"ts":"…","kind":"question","what":"rotate tokens without invalidating logins?","why":"two viable strategies; affects validator design","status":"open"}
```
`kind ∈ {action, decision, question, result}`. `what`/`why` are always plain English.

**`index.json`** (global strip): `{ "rate_limit": {"pct":37,"resets_at":"21:30"}, "spend_today_usd":128.64, "active_runs":3 }`.

### 3.3 Producers

1. **PostToolUse hook (extend existing).** Already captures tool · elapsed · status. Add: append
   one `events.jsonl` line per tool call with a **templated plain-English `what`** derived from
   the tool + args (e.g. `Read auth.ts` → "read auth.ts"), and update `run.json`
   (`current_step`, `files_touched`, `updated_at`). Deterministic, cheap, no LLM call.
2. **Agent intent lines (the `why`).** Dispatched agents emit a one-line intent before acting;
   the hook attaches it as the event's `why`. When absent, `why` is omitted (UI just shows the
   `what`). This keeps narration honest without an expensive narrator. *(A richer LLM summarizer
   is a future enhancement, not in this slice.)*
3. **Status-line script (new).** A Claude Code `statusLine` command that receives session JSON
   and writes the session-internal fields to `run.json` / `index.json`: model, reasoning,
   context %, folder, tree/worktree, and the 5-hour rate-limit timer. **Known unknown:** which
   fields the status-line payload exposes — see §6. Fields that are absent render as `—`.
4. **OTel (existing).** Remains the authoritative source for aggregate spend; reconciled into
   `index.json.spend_today_usd` and per-run `cost_usd`.

### 3.4 The renderer (FastAPI dashboard, extend)

- **Gutter** — htmx-polled list (reuse the existing ~5s refresh pattern) of run cards, each
  2–3 lines: `name` / `model·tree` / `ctx% · $ · status-glyph`. Status glyphs are non-color too
  (existing accessibility pattern): 🟢 running, ⏳ needs-you, 💤 idle, ✓ done, ✗ failed.
- **Detail pane** — clicking a card loads a detail partial: `current_step` + progress, the
  `events.jsonl` timeline (what + why), cost/token breakdown, `files_touched`, controls
  (`pause` / `kill` / `open diff`), and — when `needs-you` — the parked question + an answer box.
- **Global strip** — footer spanning the width: `⏱ 5h {pct}% → {resets_at} · today ${spend} ·
  {active} runs`.

### 3.5 The needs-you channel

When a dispatched run hits a real decision it: sets `status:"needs-you"`, writes
`parked_question`, appends a `question` event, and **polls `answer.txt`** (non-blocking to the
rest of the fleet — other runs keep going). The dashboard shows it in the gutter (`⏳`) and a
"Needs you (N)" badge; the detail pane's answer box `POST`s to the dashboard, which writes
`answer.txt`; the run reads it, appends a `result` event, flips back to `running`. Contract only
— the polling convention is documented for dispatched agents; we do not modify Claude Code's own
prompt loop here.

## 4. The autonomy quick-win — permission allowlist

Add a curated `permissions.allow` list to project `.claude/settings.json` covering read-only and
safe commands actually used in these sessions (git status/log/diff, ripgrep, test runs, file
reads, etc.) — never arbitrary code execution, never destructive ops. This is the existing
`fewer-permission-prompts` skill's job; run it against recent transcripts and merge the result.
Reversible (it's just settings); ships independently of the dashboard work.

## 5. Error handling

- **Missing status-line fields** (esp. the rate-limit timer) → render `—`, never crash.
- **Stale runs** (no `updated_at` for N minutes) → auto-mark `idle`/`stale`, surface in UI.
- **Concurrent writers** → per-run files + append-only `events.jsonl`; the global aggregate is
  computed on read, so no shared-file lock contention across agents.
- **Offline** → no external network calls anywhere in the render path (preserve d015).
- **Corrupt/partial JSON line** → skip that line, log once, keep rendering.

## 6. Open question to resolve during build

**Status-line payload fields.** Verify what Claude Code's `statusLine` JSON actually provides.
Likely present: model, workspace/cwd, cost/token context. **The 5-hour rate-limit timer + reset
is the known unknown.** If the status line doesn't expose it, fall back to: derive from OTel
request timestamps where possible, else show the timer as `—` and ship the rest. This question
does **not** block the gutter/detail/narration work — only the timer field of the global strip.

## 7. Testing

- **Unit:** feed store read/write (`run.json`, `events.jsonl`, `index.json`); status-line
  parser (incl. missing-field fallback); hook narration templating (tool+args → plain `what`).
- **Dashboard (FastAPI route tests, reuse `dashboard/tests`):** gutter list render from a
  fixture feed; detail partial render for each `status`; answer `POST` writes `answer.txt`.
- **Integration:** simulate a full run lifecycle — `queued → running → (events) → needs-you →
  answer → running → done` — and assert the dashboard renders each state and the needs-you
  badge counts correctly.
- All offline; reuse the existing pytest setup (`python -m pytest dashboard kb -q`).

## 8. Build order (for the implementation plan)

1. Permission allowlist (independent, instant pain relief).
2. Feed store + data model (`run.json` / `events.jsonl` / `index.json`) + read/write lib + tests.
3. Extend PostToolUse hook to write narration events.
4. Status-line script + parser (with the §6 fallback).
5. Dashboard: gutter → detail → global strip (htmx), with route tests.
6. Needs-you channel (parked question + answer box + resume convention) + integration test.
