---
description: Natural-language front door — describe an outcome and the Conductor plans it into a task DAG, then runs it under budget/destructive guards. Execute mode defaults Plan Gate, named-panel acceptance, and verified labor on and fails loud when required evidence is degraded. Run artifacts land under BATON_HOME/runs/<run-id>/.
argument-hint: "<what you want done>" [--execute] [--repo <path>] [--budget <n>] [--max-tier local|free|paid] [--stakes low|standard|high] [--no-plan-gate] [--no-gate] [--no-verify] [--plan-reviewers a,b] [--plan-revise:$false] [--gate-artifact <text> | --gate-diff <range>]
---

# /baton:go

You are the **Conductor**. The user describes an outcome; you plan it and drive it to
completion. Stay thin — coordinate, narrate, and let the engine and the fleet do the work.

## Steps

1. Treat `$ARGUMENTS` as the goal (strip engine flags such as `--execute`, `--repo`,
   `--budget`, `--max-tier`, `--stakes`, and the three `--no-*` escapes).

2. Run the engine:

   ```powershell
   pwsh -File "$HOME/.claude/scripts/fleet-go.ps1" -Goal "<goal>" -Json
   # add -Budget <n> and/or -MaxCostTier <tier> when the user supplied them
   # add -Execute (and optionally -RepoPath "<path>") when the user wants the fleet to
   # actually DO the work. Execute automatically enables:
   #   -PlanGate -PlanGateFailLoud
   #   -AcceptanceGate -AcceptancePanel -AcceptanceFailLoud
   #   verification with a required-profile preflight for edit tasks
   # Map --stakes low|standard|high to -Stakes only when supplied.
   # Map --no-plan-gate / --no-gate / --no-verify to -NoPlanGate / -NoGate / -NoVerify.
   # Each escape disables only that node; --no-gate still records changes.diff.
   # -PlanReviewers a,b pins the plan roster; -PlanRevise:$false skips one auto-revise.
   # Outside execute, -PlanGate and -GateArtifact/-GateDiff retain their legacy opt-in behavior.
   # Verification freezes each task's contract at the base revision, runs the check after
   # every attempt, and on failure retries once with evidence. Scope or oracle violations
   # fail closed (no retry); pass requires the check to succeed AND the task diff to be
   # non-empty. Evidence artifacts land under tasks/<id>/{contract.json,attempts.jsonl,
   # verification.json,check-output.txt}.
   ```

3. Read the returned JSON (`status`, `run_dir`, `spend`, `pending_task_id`, `report`).
   Narrate the run from `<run_dir>/events.jsonl` as terse one-liners, and surface the
   autonomous choices from `<run_dir>/decisions.jsonl` so the user can see what you
   guessed.

4. Report by `status`:
   - `completed` → show the `report` and the total spend.
   - `interrupted-budget` → the next task would cross the budget cap. Show what is
     pending (`pending_task_id`) and its estimated cost, and ASK the user whether to
     raise `--budget` and resume.
   - `interrupted-destructive` → the next task is `reversible:false` (touches master,
     force-push, out-of-worktree delete, or external publish). Describe exactly what it
     would do and ASK for explicit approval before resuming.
   - `failed` → a task could not complete; show the failing task and the event log.
   - `rejected` / `needs-polish` → the authoritative execute acceptance panel found
     blocking work. Show `## Acceptance`; retain the branch for repair/review. The run is
     not successful, and Baton never auto-merges or rolls back.
   - `acceptance-degraded` → acceptance infrastructure, a named role, or the verdict was
     unusable. Retain the labor branch and show the gate event/report for diagnosis. A
     legitimate empty/no-op diff is `completed`, not degraded.
   - `plan-rejected` → Plan Gate peer-reviewed the plan
     DAG *before* the walk and found a critical defect. Nothing ran — no worktree, no
     labor, no spend. Show the `revise_brief.md` and the `plan-review.json` verdict, and
     offer to sharpen the goal or drop the reviewers' objection before rerunning.
   - `plan-gate-degraded` → fewer than two unique/usable peers or gate infrastructure
     failed. Nothing ran; show the loud plan-gate event. The untouched execute worktree
     and branch are cleaned up through the same path as `plan-rejected`.
   - `plan-failed` / `plan-invalid` → planning produced no usable DAG; show why and
     offer to retry with a sharper goal.
   - `verification-failed` → a frozen check, scope rule, or oracle failed after labor;
     retain the evidence and branch for diagnosis.

5. Everything not on the two guards already ran without asking — do not re-litigate it.
   Point the user at the `report.md` for the full plain-English summary.

## Notes

- The Conductor never touches the user's checkout directly. Without `--execute` the
  engine only plans, routes, and logs. With `--execute`, agentic instruments (codex,
  agy, claude-cli — `agentic`/platform-eligible providers) edit a throwaway worktree
  at `<repo-parent>/.baton-worktrees/<run-id>` on branch `baton/run-<run-id>`; the
  cumulative diff is written to `<run-dir>/changes.diff` and reviewed by the named
  fail-loud acceptance panel unless `--no-gate` is supplied. The
  branch is ALWAYS left for the user to review and merge — Baton never merges. The one
  exception is a `plan-rejected` or `plan-gate-degraded` run under `--execute`: the worktree/branch are created
  before the gate but never touched, so on rejection they are discarded and the result's
  `branch`/`worktree` fields come back null (nothing to merge, nothing advertised).
- Execute enables Plan Gate by default; `--no-plan-gate` restores the legacy walk. Two
  extra artifacts land in the run dir: `plan-review.json` (the
  peer verdict + deduped findings) whenever the gate runs, and `revise_brief.md` whenever
  the verdict is `revise` or `reject`. On `revise` (auto-revise on) the plan is rewritten
  once and `plan.json` is overwritten with the revised DAG — the run then walks it with no
  re-gate. On execute, fewer than two unique/usable reviewers or infrastructure failure
  returns `plan-gate-degraded` and halts. Standalone `-PlanGate` without fail-loud keeps
  the legacy understaffed fail-open behavior.
- Every task carries `stakes` (`low|standard|high`) plus a concrete `stakes_basis`.
  `--stakes` overrides every task. Legacy plans that omit stakes still load as
  `standard` / `legacy plan omitted stakes` and execute records one warning naming
  the applied standard policy.
- Run artifacts are box-private under `BATON_HOME/runs/<run-id>/`.
- When a prompt challenger is live (see `/baton:optimize-prompt`), the run log
  carries a `shadow` event naming which prompt variant planned this run.

## Usage-aware preflight (Layer 2)

Preflight is opt-in per provider. An absent `usage_policy` block preserves the
legacy dispatch path. The repository seed contains only commented placeholders;
copy the block into the box-private `BATON_HOME/fleet.yaml` provider entry and
set `probe: true` only where Baton ships a probe adapter:

```yaml
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
      monthly_allowance: <box-private allowance>
```

For GitHub Copilot, find the allowance at **GitHub -> avatar (top-right) ->
Copilot Settings -> usage**, where it is shown as consumed/allowance. Do not
commit the account's plan name, allowance, consumption, or quota values.

For the Codex CLI adapter, Baton reads the app-server five-hour and weekly
windows and caches the raw response for about ten minutes under
`BATON_HOME/usage-probe-cache.jsonl`. Crossing either soft cap prevents that
provider from being dispatched: Baton prints one line naming the provider,
window, observed use, reset time, and policy knob, then applies the existing
quality-first one-substitute resolver. If no qualifying peer is available, the
task is held loudly. A missing, stale, timed-out, or malformed probe fails open
and dispatch proceeds normally; probe infrastructure is never itself a quota
blocker.

Token-fit and monthly-pace messages are advisory in this layer and never hold a
task. A small `surplus_spend` preference may break an otherwise eligible tie
when an adapter-backed CLI's weekly reset is within 24 hours and it retains the
required headroom. It never relaxes quality, stakes/depth, or cost ceilings and
never applies to metered API tiers. Preflight outcomes are appended to the
Usage Governor journal as `dispatched`, `rerouted`, or `held`.

## Running from the D:\dev home base

You can launch a run against any registered project without `cd`-ing into it:

- `/baton:go --<slug> <goal>` — resolve `<slug>` (a project under `D:\dev`)
  to its folder and run there. `--<slug>` is shorthand for `--project <slug>`.
- `/baton:go <goal>` from inside a project folder — runs against that folder
  (the default).
- From `D:\dev` itself with no `--project`, use `/baton:start` to pick a
  project.

See `/baton:project list` for the roster.

## Verified labor (`--execute`, or legacy `-Verify`)

Execute verification applies a freeze-then-check-then-retry contract to edit tasks by
default. `--no-verify` restores the pre-verification labor path:

- **Task fields:** A plan task with a `verify_profile` (names a profile in the repo's committed `.baton/verification.json`) and optional `allowed_paths` (constrains the task's allowed file changes) will be verification-carrying.
- **Freeze & preflight:** Before the walk, all referenced profiles resolve from the base revision and validate — unknown, missing, or lint-failing contracts halt the run with status `plan-invalid` before any spend.
- **Per-attempt check:** After each agentic attempt, the frozen contract runs. On pass (and non-empty task diff), the task succeeds. On fail, one retry runs with bounded evidence (the original task description + failure category + excerpt from check output + fix-in-place instruction); no scope broadening, same worktree.
- **Outcome:** Pass survives (green). Scope or protected-oracle violation fails closed (no retry, status `verification-failed`). Check failure on both attempts fails closed. Pass without a diff (A5 rule) fails on attempt 1 but is retry-eligible.
- **Evidence:** Durable per-task evidence lands under `<run-dir>/tasks/<task-id>/`: `contract.json` (the frozen spec), `attempts.jsonl` (one row per attempt: worker, verdict, grade, failure category, timing), `verification.json` (rollup: final verdict, grade, proves, retried flag), `check-output.txt` (raw check output). The `## Verification` section of `report.md` narrates the results.
- **Required execute profile:** `code-gen` and `code-transform` tasks without a
  `verify_profile` halt as `plan-invalid` before labor/spend and recommend `--no-verify`
  only when the operator deliberately wants the legacy path.
- **Non-execute unchanged:** Without execute or explicit legacy `-Verify`, no
  verification default is added.

## Arguments

$ARGUMENTS

## Coach footer

Non-JSON output may end with one `Next: <command>` line from the guided-use
coach — a read-only, zero-model-cost suggestion driven by local state (gate
verdicts, prompt-pool evidence, budget posture). Each suggestion appears once
per triggering state. Set the level in `$BATON_HOME/coach/config.json`
(`{"level":"off"|"quiet"|"teach"}`, default `quiet`; `teach` adds the why).
Relay the footer to the user verbatim when present.
