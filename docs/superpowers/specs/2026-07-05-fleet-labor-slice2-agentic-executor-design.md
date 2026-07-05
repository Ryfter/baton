# Fleet Labor — Slice 2: the Agentic `-Spawner` Executor

**Date:** 2026-07-05 · **Track:** "the fleet does the labor" · **Predecessor:** Slice 1
(`fleet doctor --live`, v1.10.0, d077) · **Decision:** d078

## 1. Problem

Baton's thesis is command-and-control for a fleet of coding LLMs. Slice 1 proved an
instrument *answers* a real prompt. But the executor seam at `conductor-lib.ps1:535`
is still empty: `Invoke-TaskViaFleet` routes a task to a model, records which model it
chose and the exit code, then **discards the output**. Its own doc says so — "Non-
destructive by construction — it never touches the repo; real code/merge execution is
wired by a box via `-Spawner`." Nothing turns a model's work into a repo change.

Slice 2 fills that seam: **a non-Claude agentic instrument actually edits the target
repo, the change is captured and verified by the existing acceptance gate, and it is
trivially reversible** — left on a branch for the user to merge.

## 2. Scope (decided in brainstorming)

**In:** agentic-only labor into an isolated git worktree. Only instruments that edit
files in place (codex, agy, claude-cli) are eligible. Baton runs the instrument with
its working directory set to a throwaway worktree, captures `git diff` as the artifact,
runs the acceptance gate on it, and leaves the branch for the user to merge.

**Out (→ Slice 3):** chat/local models emitting unified diffs that Baton `git apply`s
(the fragile path); auto-merge; per-provider benchmarking; routing-algorithm changes.

Rationale: same prove-first ethos that made Slice 1 land clean. codex and agy are
already-installed frontier CLIs with edit tools, so the round-trip is real immediately;
the diff-parse/`git apply` path (the part that breaks) is isolated to its own later
slice.

## 3. The central idea: proof-by-diff (output-agnostic)

Slice 1 did not parse model prose — it scored a canary. Slice 2 does not parse model
prose either: **the proof that labor happened is the worktree's `git diff` growing.**
An instrument "did the work" iff it left a non-empty diff relative to where the task
started. This sidesteps every "did it edit files or just chat back?" ambiguity and
keeps the executor independent of any provider's output formatting.

## 4. Components

### 4.1 New library: `scripts/fleet-executor-lib.ps1`

Owns the git primitives and the spawner factory. Pure of any I/O against real user
paths — every git op is `-C <worktree>`.

- **`New-RunWorktree -RepoPath -RunId`** → creates a throwaway worktree at
  `<repo>/../.baton-worktrees/<run-id>` (outside the repo tree) on a new branch
  `baton/run-<run-id>`, off the repo's current HEAD. Returns
  `@{ worktree = <path>; branch = <name>; base_sha = <sha> }`. Throws with a clear
  message (→ caller exits 2) if `RepoPath` is not a git repo or the working tree is
  dirty in a way that blocks worktree creation.

- **`Get-RunDiff -Worktree -BaseSha`** → returns the cumulative unified diff of the
  worktree against `BaseSha` as a single string (`git -C <worktree> diff <base_sha>`),
  including new/untracked files (add-then-diff, or `git diff` with `--no-index`
  fallback for untracked — see §7). Empty string when nothing changed.

- **`Test-ProviderAgentic -Provider`** → `$true` if the provider is edit-eligible.
  Rule: authoritative `agentic` marker when present (`agentic: true|false`); absent the
  marker, inferred from `platform ∈ {claude, codex, gemini}`. See §5.

- **`New-AgenticSpawner -Worktree -FleetPath [-MaxCostTier] [-Dispatcher]`** → returns
  a **scriptblock** matching the existing `-Spawner` contract exactly:
  `param($task)` → `@{ ok; spend; chose; why; alternatives }`. Inside the closure, for
  each task:
  1. Route the task's capability via `Select-Capability`, then **filter candidates to
     edit-eligible providers** (`Test-ProviderAgentic`). If none remain →
     `@{ ok = $false; chose = ''; why = "no edit-capable candidate for '<cap>'"; ... }`.
  2. Capture the pre-task diff length. Dispatch the task prompt (`"Task: <desc>"`) to
     the chosen provider **with process working directory = the worktree**
     (`Push-Location $Worktree` around the dispatch, or `Invoke-Fleet -WorkingDirectory`
     — see §7). Reuses Slice 1's `Start-ThreadJob` timeout guard via `Invoke-Fleet`.
  3. Write the task's incremental diff to `<run-dir>/tasks/<task-id>.diff` (for the
     report; best-effort, never fails the task).
  4. `ok = (post-task worktree diff is non-empty AND grew)` OR (exit 0 with an
     intentional empty change — a nonzero exit is always `ok = $false`). Precedence:
     nonzero exit → fail; else diff-grew → ok; else exit 0 + no diff → ok with
     `why = "<provider>: no changes"`.
  5. `chose`/`alternatives`/`why` populated so the conductor's per-task decision record
     and report render exactly as they do today.

- **`Remove-RunWorktree -Worktree -RepoPath [-Force]`** → `git -C <repo> worktree
  remove`. Called only on explicit discard; on success the branch/worktree is **kept**
  so the user can merge.

### 4.2 Engine seam: post-walk diff capture in `Invoke-Conductor`

The acceptance phase (step 4) today resolves its gate artifact *before* the walk, from
`-GateArtifact`/`-GateDiff`. The produced diff does not exist until the walk finishes,
so the engine needs one new optional seam:

- Add **`-DiffProvider [scriptblock]`** to `Invoke-Conductor`. When present and the walk
  completed successfully, after the walk the engine invokes it (`& $DiffProvider`) to
  get the cumulative diff string, writes it to `<run-dir>/changes.diff`
  (utf8NoBOM), and uses that file as the gate artifact — so the existing acceptance
  phase gates the real produced diff and the verdict lands in `report.md` as it does
  today. When `-DiffProvider` is **absent, behavior is byte-for-byte unchanged**
  (existing `-GateArtifact`/`-GateDiff` resolution untouched; only used as fallback).
- Empty produced diff → no gate artifact → no acceptance section (nothing to review),
  identical to a run invoked with no gate target today.

This is the minimal change: one param + a short block in step 4. `Invoke-TaskViaFleet`
and every other engine path stay exactly as they are.

### 4.3 Run command: `scripts/fleet-go.ps1` gains an execute mode

`/baton:go` is the run command. Add a switch (proposed **`-Execute`**; without it,
behavior is unchanged — the current route-and-discard run) plus `-RepoPath` (default:
current directory). When `-Execute` is set:

1. `New-RunWorktree -RepoPath $RepoPath -RunId $runId`.
2. Build `$spawner = New-AgenticSpawner -Worktree <wt> -FleetPath $FleetPath …`.
3. Build `$diffProvider = { Get-RunDiff -Worktree <wt> -BaseSha <base> }.GetNewClosure()`.
4. `Invoke-Conductor -Spawner $spawner -DiffProvider $diffProvider …` (existing
   budget/destructive guards + acceptance phase apply unchanged).
5. Report: the branch name, the run status + gate verdict, per-task picks, and a plain-
   English "N files changed on branch `baton/run-<id>` — review and merge." **Never
   auto-merges** (standing rule: the agent does not merge without the user's word).

The existing `$env:BATON_GO_TEST_SPAWN` / `BATON_GO_TEST_PLAN` / `BATON_GO_TEST_GATE`
seams remain; `-Execute` is orthogonal and its own hermetic seam (§8) uses a fake
agentic instrument.

## 5. Edit-eligibility (concept-anchored, per d025)

No agentic/chat marker exists today. Slice 2 introduces one first-class provider field:

- **`agentic: true|false`** (optional, in `fleet.yaml`). When present it is
  authoritative. When absent, eligibility is inferred: `platform ∈ {claude, codex,
  gemini}` → agentic; everything else (local, github, unset) → not.

Effect on the current seed (zero config): `claude-cli`, `codex`, `gemini-antigravity`
qualify; `ollama-*`, `lm-studio*`, `gh-copilot`, `github-models` do not and are filtered
out of edit tasks (they are simply never picked). This names the strategic concept
Slice 3 fills (a local agentic tool sets `agentic: true`; a chat-only claude entry can
set `agentic: false`), rather than hard-coding a platform check the roadmap must later
unwind. The shared `references/fleet.yaml` seed documents the field with box-private
guidance; no real box roster ships in the repo.

## 6. Data flow

```
/baton:go -Execute -RepoPath <repo> -Goal "<goal>"
  │
  ├─ New-RunWorktree → worktree + branch baton/run-<id> off HEAD (base_sha)
  │
  ├─ Invoke-Conductor (plan → DAG walk under budget + destructive guards):
  │     each task → Select-Capability → filter to edit-eligible
  │              → dispatch task prompt with cwd = worktree
  │              → ok = worktree diff grew;  task diff → run-dir/tasks/<id>.diff
  │
  ├─ post-walk: DiffProvider → cumulative git diff → run-dir/changes.diff
  │     → acceptance gate (review-capability providers, independent of laborer)
  │       → accept | polish | reject  → report.md ## Acceptance
  │
  └─ report: branch, status+verdict, per-task picks; branch kept for user to merge
```

## 7. Error handling & edge cases

- **Not a git repo / dirty tree blocks worktree** → `New-RunWorktree` throws;
  `fleet-go.ps1` writes `[Console]::Error.WriteLine(...)` and `exit 2`. No partial state.
- **Untracked/new files** in the diff: `git diff <base>` omits untracked files. Capture
  must include them — stage with `git -C <wt> add -A` before diffing against `base_sha`
  (the worktree is throwaway, so staging is harmless), or diff `HEAD` after a scratch
  commit. Spec mandates: new files MUST appear in `changes.diff`.
- **Instrument nonzero exit** → task `ok = $false` → walk stops at that task (existing
  engine behavior); branch kept for inspection.
- **Instrument hang** → Slice 1's `Start-ThreadJob` timeout guard (via `Invoke-Fleet`)
  applies; a timed-out task is a failed task.
- **Empty diff after exit 0** → task ok, `why = "no changes"`; if the *whole run*
  produced no diff, no acceptance section (nothing to gate).
- **Gate reject** → run status `rejected` (existing), branch kept.
- **Gate fail-open** → a broken/absent reviewer never blocks (existing behavior).
- **Reversibility guard interplay:** labor happens only in the throwaway worktree, so
  edit tasks are inherently `reversible:true`; the destructive-interrupt guard
  (`reversible:false`) is unaffected and still fires for genuinely destructive tasks.
- **cwd correctness:** the agentic child process must run with cwd = worktree so it edits
  the worktree, not the user's tree. Implementation pins this via `Push-Location`
  around the dispatch (or a new `Invoke-Fleet -WorkingDirectory`); the plan chooses the
  least-invasive of the two and covers it with a test that asserts the edit landed in
  the worktree and the user's cwd is untouched.

## 8. Testing (hermetic; Slice-1 pattern)

New `scripts/test-fleet-executor-lib.ps1` plus additions to `test-fleet-go.ps1` /
conductor tests. All tests use a **temp git repo** (`git init` in `$env:TEMP`), a
**temp BATON_HOME**, a **fake agentic instrument** (a `-Dispatcher` scriptblock that
writes a file into the worktree and returns exit 0), and `try/finally` teardown of every
temp path. **No test touches** real `~/.baton`, `~/.claude`, `D:\Dev\Grimdex`, or the
real `D:\dev` tree.

Branches to cover:
- worktree created off HEAD on the expected branch; `base_sha` correct.
- fake instrument writes a file → `ok = $true`, diff non-empty, new file present in
  `changes.diff` (untracked-file capture).
- fake instrument writes nothing, exit 0 → `ok = $true`, `why` = no-changes.
- fake instrument exit 1 → `ok = $false`; walk stops.
- chat/local provider (no `agentic`, platform=local) → filtered out; `Test-ProviderAgentic`
  false; `agentic: true` override on a local entry → eligible.
- `-DiffProvider` present → acceptance phase gates `changes.diff`; absent → engine path
  byte-for-byte unchanged (regression assert on an existing conductor test).
- edit lands in the worktree, user cwd untouched.
- `Remove-RunWorktree` tears down; branch retained on success.

A real codex/agy round-trip against a scratch repo is a **box-private manual smoke**
(like Slice 1's `--live`), documented in the release notes, not in the suite.

## 9. Deployment & docs

- `fleet-executor-lib.ps1` added to `bootstrap.ps1` Step 5b deploy manifest **and** a
  `test-bootstrap.ps1` deploy assert (the v1.8.0 coach-lib omission lesson).
- `commands/go.md` (or the conductor command doc) documents `-Execute` / `-RepoPath`.
- One `AGENTS.md` line documents agentic labor into a worktree.
- `references/fleet.yaml` documents the `agentic` field.
- Plugin minor bump (`1.10.0 → 1.11.0`).

## 10. House rules (§ carried from Slice 1)

965-byte arg ceiling (large prompts via stdin/files); `[Console]::Error.WriteLine` +
`exit 2` for CLI errors (never `Write-Error` under Stop); hooks always `exit 0`;
utf8NoBOM writes; `ConvertFrom-Json` ISO→DateTime re-stringify on round-trip;
`ConvertTo-Json -InputObject @(...)` for guaranteed arrays; never name vars
`$args/$input/$event/$matches/$host/$pid`; unary-comma flatten only on direct-assignment
returns; guard 0/0; box-private data never in the repo (placeholder hosts only).

## 11. Execution (per the model ladder)

Subagent-driven; streamlined ceremony (one Opus final whole-branch review, no per-task
reviewers). Haiku for transcription-grade tasks whose plan carries complete code; Sonnet
for the `New-AgenticSpawner` + engine `-DiffProvider` integration edits (multi-file
judgment); Opus for the final review.

## 12. Decisions made

- **d078** — Slice 2 = agentic-only labor into an isolated worktree; proof-by-diff;
  `agentic` provider marker (authoritative, platform-inferred fallback); engine gains a
  post-walk `-DiffProvider` seam so the existing acceptance gate verifies the produced
  diff; branch kept for the user to merge, never auto-merged. Chat/local diff-apply
  deferred to Slice 3.
