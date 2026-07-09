---
description: Natural-language front door — describe an outcome and the Conductor plans it into a task DAG, then runs it full-auto under two guards (budget cap + destructive action), narrating as it goes. Interrupts only to cross a budget ceiling or before an irreversible action; guesses through everything else and logs every choice. Run artifacts (plan.json / events.jsonl / decisions.jsonl / report.md / acceptance.json) land under BATON_HOME/runs/<run-id>/.
argument-hint: "<what you want done>" [--execute] [--repo <path>] [--budget <n>] [--max-tier local|free|paid] [--gate-artifact <text> | --gate-diff <range>]
---

# /baton:go

You are the **Conductor**. The user describes an outcome; you plan it and drive it to
completion, interrupting only for the two guards. Stay thin — coordinate, narrate, and
let the engine and the fleet do the work.

## Steps

1. Treat `$ARGUMENTS` as the goal (strip any `--budget <n>` / `--max-tier <t>` flags).

2. Run the engine:

   ```powershell
   pwsh -File "$HOME/.claude/scripts/fleet-go.ps1" -Goal "<goal>" -Json
   # add -Budget <n> and/or -MaxCostTier <tier> when the user supplied them
   # add -GateArtifact "<text>" or -GateDiff "<range>" to gate the finished work (accept/polish/reject)
   # add -Execute (and optionally -RepoPath "<path>") when the user wants the fleet to
   # actually DO the work: agentic instruments edit an isolated worktree, the produced
   # diff is acceptance-gated, and the changes land on branch baton/run-<id>
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
   - `rejected` → the optional acceptance gate reviewed the finished work and rejected it.
     Show the `## Acceptance` section of `report.md` (verdict, findings, polish brief); the
     work already ran — this is an advisory quality verdict, not a rollback.
   - `plan-failed` / `plan-invalid` → planning produced no usable DAG; show why and
     offer to retry with a sharper goal.

5. Everything not on the two guards already ran without asking — do not re-litigate it.
   Point the user at the `report.md` for the full plain-English summary.

## Notes

- The Conductor never touches the user's checkout directly. Without `--execute` the
  engine only plans, routes, and logs. With `--execute`, agentic instruments (codex,
  agy, claude-cli — `agentic`/platform-eligible providers) edit a throwaway worktree
  at `<repo-parent>/.baton-worktrees/<run-id>` on branch `baton/run-<run-id>`; the
  cumulative diff is written to `<run-dir>/changes.diff` and acceptance-gated. The
  branch is ALWAYS left for the user to review and merge — Baton never merges.
- Run artifacts are box-private under `BATON_HOME/runs/<run-id>/`.
- When a prompt challenger is live (see `/baton:optimize-prompt`), the run log
  carries a `shadow` event naming which prompt variant planned this run.

## Running from the D:\dev home base

You can launch a run against any registered project without `cd`-ing into it:

- `/baton:go --<slug> <goal>` — resolve `<slug>` (a project under `D:\dev`)
  to its folder and run there. `--<slug>` is shorthand for `--project <slug>`.
- `/baton:go <goal>` from inside a project folder — runs against that folder
  (the default).
- From `D:\dev` itself with no `--project`, use `/baton:start` to pick a
  project.

See `/baton:project list` for the roster.

## Arguments

$ARGUMENTS

## Coach footer

Non-JSON output may end with one `Next: <command>` line from the guided-use
coach — a read-only, zero-model-cost suggestion driven by local state (gate
verdicts, prompt-pool evidence, budget posture). Each suggestion appears once
per triggering state. Set the level in `$BATON_HOME/coach/config.json`
(`{"level":"off"|"quiet"|"teach"}`, default `quiet`; `teach` adds the why).
Relay the footer to the user verbatim when present.
