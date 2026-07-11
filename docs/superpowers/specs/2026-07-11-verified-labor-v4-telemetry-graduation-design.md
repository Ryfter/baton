# Verified Labor V4 — Observe-only telemetry + require-verify graduation (d082 slice V4)

**Date:** 2026-07-11 · **Status:** SPEC — authored async (Kevin away); build gated on his
review + the graduation-flip decision in §7 · **Decision:** d082 (slice V4; A4 ruling) ·
**Priority:** #5 in Kevin's 2026-07-11 order · **Spine:** `codex-ringer.md` governs where silent.

## 1. What this is

Two halves that ship together (d082 slice V4):

1. **Observe-only verification telemetry** — fold the evidence V2/V3 already write
   (`tasks/<id>/attempts.jsonl`, `verification.json`) into a **receipts scoreboard**: per
   `capability × worker`, the first-try-pass / rescued-on-retry / infra-fail rates, the
   grade mix (`strong|bounded|weak`), and sample counts. Ringer's lesson: *receipts, not
   leaderboards.* It **reports**; it does not route.
2. **Require-verify graduation** — flip the default so `-Execute` edit tasks
   (capability ∈ {code-gen, code-transform}) **require** a `verify_profile`, with an explicit
   `-AllowUnverified` escape. This kills the "verify-optional death spiral" (A4's strongest
   finding): a forever-optional check is a check no one adopts.

## 2. Why the two ship together

The graduation flip is only safe once the telemetry exists to show it isn't breaking runs —
you flip the default *and* you can watch the first-try/infra rates to confirm the fleet is
actually clearing the bar. Shipping the receipts in the same slice gives the flip its
safety instrument.

## 3. Part 1 — Observe-only telemetry

### 3.1 Source of truth (already produced — no new capture)

V2/V3 write per task: `attempts.jsonl` (one row per attempt: worker, verdict, grade,
failure_category, duration, spend) and `verification.json` (final outcome). V4 **reads**
these across `$BATON_HOME/runs/*/tasks/*/` — zero new instrumentation on the hot path.

### 3.2 The fold (`scripts/verify-stats-lib.ps1`, new)

- `Get-VerifyReceipts [-Since <date>] [-Capability <c>] [-Worker <w>]` → for each
  `capability × worker` bucket: `n` (sample count), `first_try_pass`, `rescued`
  (passed on attempt 2), `infra_fail`, `check_fail`, `scope_violation`, and the grade mix
  fractions. Every rate is `count / n` with the divide **guarded** (n=0 → the bucket renders
  `insufficient_data`, never `0%` — A2's no-fabrication rule).
- **Hard boundary (d082 §slice V4 + d059):** V4 **never writes `effective-cost.json`** and
  **never mutates routing weights**. It is a read-only lens. Any routing use of these
  receipts is a separate, later weights/floors decision — explicitly out of scope here.

### 3.3 Surface

A `/baton:verify-stats` command (and a compact panel inside `/baton:usage`) renders the
scoreboard: stable row order (capability, then worker), sample counts always shown, low-n
buckets flagged. No second dashboard (A2); no Chart.js until real volume exists.

**Relationship to the other observe-only tracks (keep them distinct):** V4 measures
verification **quality** (did the work pass, first try?); token telemetry measures
**consumption**; usage-aware failover measures **remaining quota**. Three different axes —
V4 owns the reliability receipts only.

## 4. Part 2 — Require-verify graduation

### 4.1 The flip

- Under `-Execute -Verify`, a task with capability ∈ {code-gen, code-transform} and **no**
  `verify_profile` becomes `plan-invalid` **before labor** (fail-closed, no spend) — unless
  `-AllowUnverified` is passed, which downgrades it to a `task-unverified` warning event and
  proceeds (the V2 unverified path, now opt-*out* instead of default).
- Mirrors the Plan Gate's opt-in→default-on graduation exactly (d080 pattern). "Optional
  forever" is rejected (A4).

### 4.2 Preconditions this flip assumes (must be true first)

- **V1 presets exist** (`references/verify-presets.json` — shipped): so authoring a profile
  is a one-liner (`verify_profile: pytest`), not hand-written argv.
- **Planner teaches `verify_profile`** (V2 few-shots): the planner already selects a preset
  for edit tasks, so most plans arrive verify-ready. The flip mostly catches the gaps.
- If either regresses, the flip would turn every unprofiled edit task into `plan-invalid` —
  so §7 makes the flip a **named decision Kevin signs off**, not an automatic default.

### 4.3 Messaging (legibility north star)

When a task is rejected for missing verification, the report says plainly: *"t3 (code-gen)
needs a verify_profile — add one (e.g. `verify_profile: pwsh-suite`) or re-run with
-AllowUnverified."* An operator must never be confused about why labor didn't start.

## 5. Scope

**In:** the receipts fold + `/baton:verify-stats` + the `/baton:usage` panel; the
require-verify preflight flip + `-AllowUnverified` escape + clear messaging; bootstrap
manifest + deploy-assert for `verify-stats-lib.ps1`; plugin minor bump.

**Out:** any routing/weights change from the receipts (separate later decision — the
firewall d082 draws around d059); the cockpit/Chart.js UI (V5); cross-machine receipt
aggregation (Tailscale fleet — later); tier-aware or usage-aware routing (separate tracks).

## 6. Tests (hermetic — temp BATON_HOME with synthetic run dirs; never touch real
`~/.baton`/`~/.claude`/`D:\Dev\Grimdex`/`D:\dev`)

- Receipts fold: seed synthetic `attempts.jsonl` across two workers × two capabilities →
  assert first-try/rescued/infra rates and grade-mix fractions exact; guard n=0 →
  `insufficient_data` (no divide-by-zero, no fabricated 0%).
- `effective-cost.json` is **never written/touched** by any V4 code path (assert the file's
  mtime/content is unchanged after a stats run — the d059 firewall).
- Graduation flip: a code-gen task with no profile → `plan-invalid` before any spawn (assert
  zero spend, zero worktree); same task with `-AllowUnverified` → `task-unverified` warning +
  proceeds; a non-edit capability (summarize) is unaffected by the flip.
- `/baton:verify-stats` renders stable order + sample counts; low-n flagged.
- Bootstrap deploy-assert for the new lib.

## 7. Open decisions — batched for Kevin

- **Fork V4-A — flip the default now, or ship telemetry first and flip later?** A4 rules the
  flip happens; the timing within V4 is Kevin's. *Default:* ship both together (telemetry as
  the safety instrument for the flip) but keep the flip behind a one-release **grace** where
  a missing profile is a *loud warning*, not `plan-invalid`, so real plans surface any gaps
  before the hard fail turns on. Kevin may prefer the hard flip immediately.
- **Fork V4-B — graduation capability set.** Default {code-gen, code-transform}. Kevin may
  want it narrower (code-gen only) or wider (any edit capability) initially.

## 8. House rules

965-byte args; `[Console]::Error.WriteLine` + exit 2; hooks exit 0; utf8NoBOM; ConvertFrom-
Json ISO re-stringify; `ConvertTo-Json -InputObject @(...)`; never `$args`/`$input`/`$event`;
unary-comma only on direct-assignment returns; guard every divide; box-private placeholder
hosts only; fail-CLOSED verification posture; the d059 effective-cost firewall is absolute.
Ladder: subagent-driven, Sonnet for the fold + preflight integration, Haiku for
transcription tasks, Opus final whole-branch review; streamlined ceremony.
