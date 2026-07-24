# Engine expressiveness — task-output bus + engine-owned rework (design)

**Date:** 2026-07-24 · **Status:** DRAFT — awaiting Kevin's review · **Issues:** #115, #128 (+C3
unparked), with #127 as adjacent evidence · **Driving evidence:** the #93 bakeoff's terminal
finding (report §6): *the quality gates are ahead of the execution engine.* Terms per
`docs/glossary.md`.

## 1. The problem, as proven

Two facts, each demonstrated live on 2026-07-23 (run `go-2026-07-23T17-41-30`):

1. **Task outputs cannot flow.** Workers receive only `Task:{desc}`. A research task's findings
   and a review task's fix list have no path to the tasks that need them. The planner
   compensates by stuffing guesses into descriptions — which the plan gate then correctly
   flags as guesses.
2. **The Catch-22.** The plan gate (correctly) requires a remediation path after review. The
   plan language has no conditional tasks, so the planner's only move is an always-on
   remediation task — which no-ops on the happy path, and A5 (correctly) demotes an empty diff
   to failure. Plans with review are therefore unexecutable: no remediation task = missing-task
   finding; always-on remediation task = guaranteed no-change failure.

Both gate behaviors and both engine behaviors are individually right. The gap is between them.

## 2. Design principle

**Remediation is control flow, and control flow belongs to the engine, not the DAG.** We do not
add conditional-task syntax to the plan language (a `run_if` field would push branching logic
into an LLM-authored artifact the gate would then have to verify — moving the Catch-22, not
solving it). Instead: plans stay straight-line (research → implement → review), and the engine
owns the fail→rework→re-verify loop, journaled like every other autonomous act.

## 3. Slice 1 — the task-output bus (#115, the data half)

- Every task's worker prompt gains a final instruction: end with a fenced `## Task output`
  block — the structured residue the next task needs (research: file paths + facts; review:
  verdict + numbered fix list; implement: what changed + flags). The spawner extracts it
  (fail-soft: absent block → whole tail up to a cap) and writes
  `tasks/<id>/output.md` in the run dir.
- When a task declares `depends_on: [t1]`, the spawner injects each dependency's output into
  its prompt under `## Inputs from t1`, size-capped per dependency (default 8 KB, config
  knob), oldest-first truncation with an explicit `(truncated)` marker — never silent.
- Contract: the bus is **advisory data, not authority** — verification contracts still freeze
  from the base revision; a poisoned/wrong output can waste a task but cannot widen scope
  (allowed_paths) or weaken the oracle. States this explicitly in code comments.
- Box-private: run dirs already are.

## 4. Slice 2 — engine-owned rework (C3, the control half)

When a task's verification fails on a check (not scope/oracle violations — those stay
fail-closed, no retry, unchanged) **or** the acceptance panel returns `needs-polish` with
findings:

1. The engine synthesizes ONE rework task: description = the verbatim findings/fix list (via
   the bus), `allowed_paths` = the failing task's own, `verify_profile` = the same, stakes
   inherited. Nothing is invented by the engine; it only re-packages evidence.
2. Rework runs through the normal spawner + verification. Pass → walk continues. Fail →
   **halt loudly** with both attempts' evidence attached.
3. **Hard ceiling, mechanical:** `max_rework: 1` per task per run (config knob, default 1;
   ceiling enforced by a counter in engine code, never by prompt text — the self-correcting-
   loop residue rule, Grimdex note 2026-07-18). The engine never re-sends identical feedback:
   if the second failure's findings are byte-identical to the first's, it halts instead of
   looping.
4. Every rework is journaled (`task-rework-started/-passed/-failed` events + a decisions.jsonl
   row naming what evidence triggered it) — the operator can always answer "why did this run
   twice."
5. This SUBSUMES the existing "one evidence-informed retry" on verification failure — the
   current retry becomes rework cycle #1 rather than a separate mechanism (one loop, one
   counter, one journal vocabulary).

## 5. Slice 3 — the gate checklist adjustment (closing the Catch-22)

With Slices 1–2 in, the plan gate's reviewer briefing changes: an in-DAG remediation task is no
longer demanded (and SHOULD be flagged as overbuild — the engine owns rework). The gate's
"missing-task: no remediation path" class retires; a new line in the gate prompt states the
engine's rework contract so reviewers evaluate plans against the real semantics. This is a
prompt/config change plus tests — no reviewer-side code.

## 6. Out of scope

Conditional-task syntax in the plan language (rejected above); multi-cycle rework ladders
(ceiling stays 1 until evidence demands more); tier auto-escalation (#127 keeps its own track);
mid-DAG *gate-type tasks* (the other half of #115 — separate slice, later, rides the same bus);
cross-run memory of rework patterns (memory-ingest #121 already captures outcomes).

## 7. Verification & acceptance

Each slice hermetically tested (fixture runs, fake spawners — existing test-conductor/executor
patterns). End-to-end acceptance for the arc: **the bakeoff S1-A brief, unmodified, passes the
plan gate and reaches labor** on a plan shaped research → implement → review — the exact case
that failed on 2026-07-23. That run (whatever its labor outcome) is the arc's ship gate, and
un-blocks resuming the #93 head-to-head.

## 8. Execution order

1. Kevin reviews this spec (redirects welcome — Slice 2's ceiling default and Slice 3's gate
   wording are the two most judgment-laden calls).
2. Slice 1 → Slice 2 → Slice 3, each through the standard pipeline (Grok builds, Opus
   refutes, gate, PR, Kevin's word). Codex stays out per the sparingly policy unless a slice
   proves genuinely hard.
3. Then: #93 Arm A re-run resumes.
