# Diff-apply worker path — design

**Decision:** `d103` (Path B). **Closes:** `#168`. **Revisits:** `d009`.
**Date:** 2026-08-03

## Problem

`Test-ProviderAgentic` returns `$false` for `kind: http` and `kind: stdio-json`
unconditionally (`fleet-executor-lib.ps1:131`). Those transports have no filesystem
harness, so an `agentic: true` marker cannot honestly grant them edit powers — the d091
veto is correct and stays.

The consequence is that Baton has **no free or local implementer at any stakes level**.
`Resolve-TaskDepthPolicy` caps `stakes=low` at the `free` cost tier, every agentic
`code-gen` provider is `paid`, so a well-formed low-stakes edit task is undispatchable
(#168, observed as run 9's plan-gate critical).

It also wastes the best-ranked candidate. After the #159 ratings seeding, `lm-studio`
ranks **first** for `code-gen` on cost (`local`) *and* quality (`0.625`, the highest of
any candidate). It is refused for having no hands, not for being bad.

This matters more every week: the operator's paid subscription is dropping ~5x. The
natural response — plan more work at low stakes — currently makes *more* tasks
undispatchable, exactly backwards.

## What this builds

Baton becomes the hands. A **diff-apply worker path**: Baton reads the files, the model
returns edit blocks as text, Baton applies them to the worktree. Everything downstream —
proof-by-diff, the frozen verification contract, the scope oracle, the rework loop — runs
byte-for-byte unchanged, because they all judge the worktree, not the worker.

The design has two halves, and the second is not optional.

### Half 1: hands (the mechanism)

A parse-and-apply path that converts model text into worktree edits, deterministically
and safely.

### Half 2: right-sizing (the envelope)

Field evidence from the operator: a practitioner doing this work uses **Haiku for all
coding** and it works — because the tasks are atomized into very small units. The same
is reported as the key to using local models at all. Task size, not model tier, is the
variable that decides whether a cheap model succeeds.

This has a sharp corollary for Baton's own data. `(code-gen, claude-haiku)` currently
rates **0.462 — last among paid candidates** — from three real scope violations. Every
one of those was a large task chunk. If the atomization hypothesis holds, **that score is
measuring chunk size, not model competence**, and Baton is systematically mis-rating cheap
models for failures that were really size failures.

We do not know the right size. Nobody does — it has to be found by observation. So this
design ships:

1. a **conservative size envelope** the dispatcher enforces up front, and
2. an **observation record** that captures size alongside outcome on every attempt,

so the correct level is *discovered from data* rather than declared. The envelope defaults
are deliberately provisional and are expected to move once there is evidence.

## Edit format

The format is chosen for one property: **a small model can produce it, and a parser can
reject a malformed one loudly.** Silent corruption is the only unacceptable failure.

Rejected alternatives:

- **Unified diff** — requires correct line numbers and hunk headers. Small models fail
  this constantly, and a wrong `@@` header is exactly the silent-corruption case.
- **Whole-file rewrite as the primary op** — parses reliably, but forces the model to
  reproduce every line of the file. Token-expensive, and small models silently drop code.
  Retained *only* for file creation.

**Chosen: SEARCH/REPLACE blocks.** The model quotes exact existing text and its
replacement; application is a literal string match. Widely present in model training data
(it is the aider format), and its failure mode is loud: no match means no write.

### Grammar

    FILE: <repo-relative path>
    <<<<<<< SEARCH
    <exact existing text>
    =======
    <replacement text>
    >>>>>>> REPLACE

Rules:

- Multiple blocks per response, any order. Each block carries its own `FILE:` line.
- The `FILE:` line must be the last non-blank line before `<<<<<<< SEARCH`.
- Marker lines (`<<<<<<< SEARCH`, `=======`, `>>>>>>> REPLACE`) must start at column 0 and
  match exactly. Trailing whitespace is tolerated; trailing content is not.
- Prose outside blocks is ignored — models chatter, and that is fine.
- An **unterminated or malformed block is a hard parse failure for the whole response.**
  Never silently drop a block: a dropped edit looks like success and produces a
  half-implemented task.
- **Empty SEARCH section = create file.** The replacement is the whole file content. If
  the file already exists, this is an error (prevents accidental clobber). Creation is the
  only whole-file op.

### Application

Exact ordinal match, **no fuzzy matching** — fuzzy matching is precisely where silent
corruption enters.

- Search text occurring **0 times** → error `search-not-found`.
- Search text occurring **2+ times** → error `search-ambiguous`. The model must quote more
  context; guessing which occurrence was meant is not acceptable.
- **All-or-nothing.** Every block is applied to an in-memory copy of the file set first.
  Only if all blocks succeed is anything flushed to disk. A half-applied response is worse
  than no response, because verification would judge an incoherent tree.
- Multiple blocks may target the same file; they apply in order against the accumulating
  in-memory copy, so a later block can match text an earlier block wrote.

### Byte-level fidelity (Windows traps)

- **Line endings:** detect the target file's dominant EOL. Normalize model output to LF,
  then to the target's EOL before matching and before writing. New files use LF.
- **Encoding:** `utf8NoBOM` by default; if the original file had a BOM, preserve it.
- **Final newline:** preserve the file's existing trailing-newline state.

Getting any of these wrong turns a one-line edit into a whole-file diff, which then trips
the diff-growth check and looks like a scope violation.

## Safety invariants

The scope oracle and frozen verification contract remain **the sole authorities**. Nothing
below weakens them; these are early, cheap rejections that turn a voided run into an
actionable rework signal.

1. **Path containment.** Every `FILE:` path resolves inside the worktree root. Reject
   absolute paths, drive-qualified and UNC paths, any `..` segment, empty segments, and
   control characters. Verify by resolving the full path and confirming it is prefixed by
   the worktree root plus a separator.
2. **No writes through symlinks.** If an existing target has the `ReparsePoint` attribute,
   refuse. This is the containment-escape vector that pure string checks miss.
3. **Never write under `.git/`.**
4. **allowed_paths pre-check.** Reuse `Test-DiffFilesInAllowedPaths` from
   `verification-lib.ps1` — the same matcher the oracle uses. Do not reimplement the
   matching rule; a second implementation that drifts is worse than no check.
5. **All-or-nothing application**, per above.
6. **Empty response is not success.** A model that returns prose and no blocks yields
   `ok=$false` with a specific reason, not a silent no-change pass.

**Safety is not reduced by admitting cheaper implementers.** The oracle judges the diff,
not its author — run 8 caught a *paid frontier* model rewriting a schema it was never
asked to touch. A local model's bad diff is caught by exactly the same gate.

## Integration

### Predicates

`Test-ProviderAgentic` **does not change.** Tests A9/A10 assert the d091 transport veto
and must keep passing. A marker still cannot conjure a filesystem harness.

Add:

- `Test-ProviderDiffApply -Provider` → `$true` when the provider opts in via
  `diff_apply: true` **and** its transport is one Baton can drive text-only
  (`kind: http` or `kind: stdio-json`).
- `Test-ProviderEditCapable -Provider` → `Test-ProviderAgentic` **OR**
  `Test-ProviderDiffApply`. This is the predicate that edit-eligibility checks switch to.

Config opt-in is the gate. There is no env-var flag: a provider is a diff-apply
implementer only when its fleet row says so, which keeps the blast radius per-provider and
under the operator's control.

### Call sites switching to `Test-ProviderEditCapable`

- `New-AgenticSpawner` candidate filter (`fleet-executor-lib.ps1:826`)
- `Resolve-AgenticSubstituteCandidates` (`:439`)
- `Get-CapabilityCostTierFloor` (`:168`) — **this is what actually closes #168**, by
  letting the planner see that a free/local floor exists for `code-gen`
- `Get-EditPoolExclusions` (`:235`) — with a distinct reason string so an excluded
  provider says *why* (`not edit-eligible (no diff_apply opt-in)`)
- `Test-PlannerProviderEditEligible` (`conductor-lib.ps1:429`), which mirrors the
  predicate. The existing eligibility-agreement test
  (`test-fleet-executor-lib.ps1:234`) must still pass — it is the guard against these two
  drifting apart.

### Dispatch branch

In the spawner, after the pick is chosen:

- agentic provider → existing `Invoke-AgenticDispatchAttempt` (unchanged path)
- diff-apply provider → new `Invoke-DiffApplyAttempt`

`Invoke-DiffApplyAttempt` assembles context, dispatches via the ordinary `Invoke-Fleet`
call, parses, validates, applies, and returns the **same result shape** the agentic path
returns. Everything after the branch — `Get-WorktreeTreeSha` proof-by-diff, the per-task
diff file, usage observation, verification — is untouched.

## Context assembly and the size envelope

Baton selects what the model sees. It reads files from the worktree under the task's
`allowed_paths`, subject to the envelope.

Per-provider config, under the fleet row:

    diff_apply: true
    diff_apply_limits:
      max_context_bytes: 24000
      max_files: 4
      max_blocks: 8

Defaults when unset: `max_context_bytes: 24000`, `max_files: 4`, `max_blocks: 8`. These
are **provisional and conservative on purpose** — 24 KB sits under the existing 35 KB
context-overflow floor with headroom for the response, and the file/block caps encode the
atomization thesis as an enforced envelope rather than a hope.

Interaction with `max_prompt_bytes`: the effective context budget is
`min(max_context_bytes, max_prompt_bytes - reserve)`. The assembled prompt must fit.

**When a task does not fit the envelope**, the provider is skipped for that task with a
specific reason (`task exceeds diff-apply envelope: N bytes > limit`), and selection falls
through to the next candidate. It is a routing signal, not a failure — and it is the
single most valuable row in the telemetry, because it marks where atomization was needed
and absent.

Truncation is **not** an option. A model asked to edit a file it was shown only half of
will produce a SEARCH block that cannot match, or worse, one that matches the wrong
region.

## Observation record

Every diff-apply attempt appends one JSONL row to
`$(Get-BatonHome)/diff-apply-observations.jsonl`:

| field | meaning |
|---|---|
| `ts` | ISO-8601 UTC |
| `run_id`, `task_id` | join keys to the run record |
| `provider`, `model_version` | who did it (version is mandatory — a capability claim without a version is worthless) |
| `context_bytes`, `file_count` | **the size half of the hypothesis** |
| `blocks_emitted`, `blocks_applied` | did it produce well-formed edits |
| `parse_result` | `ok` / `malformed` / `empty` |
| `apply_result` | `ok` / `search-not-found` / `search-ambiguous` / `path-rejected` / `scope-rejected` |
| `verdict` | downstream verification outcome, joined after the fact |

This is the dataset that answers "what is the correct level?" — for local models *and* for
Haiku. It feeds the jagged-edge flywheel
(`2026-08-02-jagged-edge-flywheel-design.md`), which already exists as the consumer.

Writing the row must never fail the task. Fail-soft, always.

**Rating interaction.** A `search-not-found` on an oversized context is a size failure,
not a quality failure. Per the #156 precedent — availability is not quality, and quota
refusals write no rating — **envelope rejections and parse failures on oversized contexts
write no capability rating.** Only failures inside the envelope are evidence about the
model.

## Testing

Hermetic, per the standing rule: never touch real `~/.baton`, `~/.claude`, or a real
project tree. Temp `BATON_HOME`, placeholder fleet rows only (no real model ids or
endpoints).

- **Parser:** well-formed single and multi-block; prose around blocks; malformed/unterminated
  → hard failure; empty response → `empty`; empty-SEARCH create; empty-SEARCH on an
  existing file → error.
- **Applier:** exact match; 0 matches; 2+ matches; multi-block same file in order;
  all-or-nothing (a late bad block leaves the tree untouched — assert by tree sha);
  CRLF and LF files; BOM preserved; trailing-newline preserved.
- **Safety:** `..` escape, absolute path, UNC, `.git/` write, symlink target, out-of-scope
  path each rejected with its own reason.
- **Envelope:** over-budget task skips the provider with the specific reason; under-budget
  proceeds.
- **Predicates:** `Test-ProviderAgentic` unchanged (A9/A10 still pass);
  `Test-ProviderDiffApply` true only with opt-in *and* a text transport;
  planner/executor eligibility agreement still holds.
- **End-to-end:** a fake dispatcher returning canned edit blocks drives a real worktree
  through the spawner and proves the tree changed, the per-task diff was written, and the
  result shape matches the agentic path's.

## Out of scope

- **Do not relax `Test-ProviderAgentic`.** A marker cannot conjure a harness.
- **No fuzzy matching, ever.**
- **No automatic task splitting.** This design measures where the envelope bites; teaching
  the planner to atomize is the follow-on, and it should be driven by the data this
  produces, not guessed now.
- **No changes to the oracle, the frozen contract, or the rework loop.**
- **Path A is not foreclosed.** Wrapping a local model in a third-party agentic CLI
  harness remains worth doing opportunistically for a specific model; it was rejected only
  as the *primary* path, because it is a per-model dependency and does nothing for
  free-tier HTTP.

## Deployment

`scripts/bootstrap.ps1` deploys an explicit inclusion list, and it has silently omitted
new scripts **three times running** (#166). Every new script here must be added to it, and
the deploy verified by confirming the repo and `~/.claude/scripts` are byte-identical
before any live claim.
