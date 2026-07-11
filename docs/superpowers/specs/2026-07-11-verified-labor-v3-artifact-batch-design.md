# Verified Labor V3 — Artifact-batch parallelism (d082 slice V3)

**Date:** 2026-07-11 · **Status:** SPEC — authored async (Kevin away); build gated on his
review · **Decision:** d082 (slice V3; A1 ruling) · **Priority:** #4 in Kevin's 2026-07-11
order · **Spine:** `codex-ringer.md` governs where silent; V2 code is the substrate.

## 1. What this is

V2 verifies one task at a time along a **sequential** DAG walk. V3 is the first
parallelism slice (d082 A1: "the swarm joy arrives one slice after trust, not four"): run
the **ready-set** of independent tasks **concurrently**, each writing only into its own
per-task artifact directory (**no repo edits** — that stays V5), each verified by its own
frozen contract exactly as in V2. This is the demo slice — the first time Baton visibly
farms a batch of work across the fleet at once and checks all of it.

**The V3/V5 line (A1):** V3 tasks are *artifact-producing* — they write deliverables into
`tasks/<id>/artifacts/` under the run dir, never into the target repo. Repo-editing tasks
(child worktree per task, durable branch/patch) are V5. Keeping V3 non-repo-edit removes
the hardest concurrency hazard (worktree/index contention) so the parallel machinery can be
proven on safe ground first.

## 2. Where it plugs into V2

Three real anchors in today's code:

- **The Kahn walk** — `conductor-lib.ps1` derives indegrees and a ready-queue
  (`$indeg`, `$ready`, the `while ($ready.Count -gt 0)` loop). Today it pops **one** ready
  id per iteration and processes it inline. V3 drains the **whole** current ready-set each
  round and dispatches it concurrently, then folds completions and recomputes the ready-set.
- **`New-VerifyingSpawner`** (`fleet-executor-lib.ps1`) — the per-task verify wrapper from
  V2 is reused unchanged per task; V3 changes *how many run at once*, not *how one is
  verified*. Each task's baseline-freeze / run / check / precedence logic is already
  self-contained per task.
- **`Start-ThreadJob`** — already a house concurrency primitive (`fleet-probe-lib.ps1` uses
  it for the canary timeout guard). V3 uses a **bounded** pool of them (semaphore) rather
  than a runspace pool, to stay on a primitive the codebase already ships and tests.

## 3. Architecture

### 3.1 Ready-set scheduler (`New-BatchScheduler` in a new `scripts/fleet-batch-lib.ps1`)

- Input: the normalized task list (with `depends_on`), a per-task work scriptblock
  (the V2 verifying spawner closure), and `-MaxConcurrency` (default **3**, override via a
  new optional `batch_max_concurrency` fleet field; hard ceiling 8).
- Loop: compute the ready-set (indegree 0, not yet dispatched); dispatch up to
  `MaxConcurrency` in flight via `Start-ThreadJob`; as each finishes, record its result,
  decrement successors' indegrees, refill from the new ready-set. Terminates when all tasks
  are terminal or a **fail-closed** result halts the batch (see §3.4).
- **Determinism:** dispatch order within a ready-set is stable (task-id ascending) and the
  final report renders tasks in original plan order regardless of completion order. The
  scheduler itself never depends on wall-clock completion order for correctness.

### 3.2 Per-task isolation (the safety guarantee)

- Each task runs with its artifact dir `tasks/<id>/artifacts/` as its declared writable
  scope; `allowed_paths` (V2) is enforced against that dir. A task whose worker writes
  outside its artifact dir → **scope-violation**, fail-closed (V2 precedence, unchanged).
- No shared mutable filesystem state between concurrent tasks: distinct artifact dirs,
  distinct evidence trees (`tasks/<id>/{contract.json,attempts.jsonl,verification.json,
  check-output.txt}`). This is why V3 is non-repo-edit — one shared worktree would
  reintroduce contention.

### 3.3 Thread-safe shared state (the concurrency hazards to design against)

Three things V2 mutated inline that now cross threads:

1. **Spend accumulation** — replace the running `$totalSpend` with per-task spend written
   to each task's result object; the parent **sums after join** (no shared counter mutated
   from threads).
2. **Event emission / journal writes** — each thread writes events to its **own**
   `tasks/<id>/attempts.jsonl`; run-level events (`task-verification-started/passed/failed`,
   etc.) are emitted by the **parent** as it folds each completion, never from inside the
   thread. `Write-FleetJournalLine`'s `Add-Content` is append-only but not atomic across
   processes — so journal lines are written by the parent post-join, serialized.
3. **The frozen-contract table** — read-only across threads (frozen at preflight before the
   batch starts, exactly as V2's shared `$frozen`). Never mutated during the batch.

### 3.4 Outcome precedence in a batch

Per-task precedence is V2's, verbatim. Batch-level rules (new):

- A **fail-closed** task (scope-violation / oracle mutation) **stops new dispatch** — in-
  flight tasks drain, no new ones start, batch status → `verification-failed`. An adversary
  gets no parallel cover to slip more tampering through.
- A retry (check-fail / timeout / no-change) is confined to its own task's slot — the V2
  one-retry bound is per task and does not consume a second concurrency slot beyond that
  task's own.
- All-pass → batch `completed`; the acceptance gate runs once over the union of artifacts.

## 4. Report / narration (A2 constraint)

The Gemini narration format is binding: `route → worker → check → retry → proves` per task.
V3 renders the batch as a stable-ordered list under a `## Verification` block plus a one-line
batch header (`N tasks, M concurrency, P passed / R rescued / F failed`). No second
dashboard (A2). Placeholder/aggregate metrics that lack samples render `insufficient_data`,
never fabricated.

## 5. Scope

**In:** ready-set scheduler + bounded concurrency; per-task artifact-dir isolation; reuse of
V2 verification per task; thread-safe spend/event/journal handling; batch-level precedence;
parallel-aware narration; opt-in (rides the existing `-Verify`/batch flag — default path
unchanged); bootstrap manifest + deploy-assert for `fleet-batch-lib.ps1`; plugin minor bump.

**Out:** repo-editing parallel tasks / child worktrees (V5); the cockpit UI (V5, A2); any
routing/telemetry change (V4); cross-machine fan-out (Tailscale fleet — later).

## 6. Tests (hermetic — temp BATON_HOME + temp dirs + try/finally; never touch real
`~/.baton`/`~/.claude`/`D:\Dev\Grimdex`/`D:\dev`; injectable fake spawner, no real CLIs)

- Ready-set derivation: diamond DAG (A→{B,C}→D) dispatches B+C concurrently, D only after
  both; linear chain never exceeds concurrency 1 in flight.
- `-MaxConcurrency` respected: never more than N in flight (instrument the fake spawner with
  a concurrency high-water counter, guarded by an interlocked increment).
- Determinism: shuffle fake-spawner completion order → identical final report + identical
  summed spend.
- Isolation: a fake worker writing outside its artifact dir → scope-violation, fail-closed,
  **batch halts new dispatch** (assert a queued sibling never starts).
- Per-task retry stays per-task (one task's retry doesn't delay/among-count others).
- Spend sums correctly across parallel completions (no lost updates).
- Bootstrap deploy-assert for the new lib.

## 7. Open decisions — batched for Kevin

- **Fork V3-A — concurrency primitive.** `Start-ThreadJob` (house-proven, simple, ~per-job
  overhead) vs a `RunspacePool` (lower overhead at higher fan-out, more machinery).
  *Default:* Start-ThreadJob — matches the existing codebase, and V3's fan-out is small
  (default 3, ceil 8). Revisit at V5/cross-machine scale.
- **Fork V3-B — default `MaxConcurrency`.** *Default:* 3 (safe for paid-tier rate limits;
  overridable per box). Kevin may want a different floor given real fleet rate caps.

## 8. House rules

965-byte args; `[Console]::Error.WriteLine` + exit 2; hooks exit 0; utf8NoBOM; ConvertFrom-
Json ISO re-stringify; `ConvertTo-Json -InputObject @(...)`; never `$args`/`$input`/`$event`;
unary-comma only on direct-assignment returns; guard 0/0; box-private placeholder hosts only;
fail-CLOSED verification posture. Ladder: subagent-driven, Sonnet for the scheduler
integration, Haiku for transcription tasks with complete code, Opus final whole-branch review
(concurrency correctness — the review that most earns its cost here); streamlined ceremony.
