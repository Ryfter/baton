# Codex comparative critique: Grok and Gemini Ringer proposals

**Reviewer:** Codex
**Date:** 2026-07-10
**Artifacts reviewed:** [`grok-ringer.md`](grok-ringer.md) and [`gemini-ringer.md`](gemini-ringer.md)
**Codex baseline:** [`codex-ringer.md`](codex-ringer.md)
**Detailed Grok review:** [`codex-ringer-critique.md`](codex-ringer-critique.md)
**Repository state reviewed:** Baton `feature/plan-gate` at `af9830f`
**Purpose:** Preserve the best thinking from all three proposals while rejecting unsafe, duplicative, speculative, or ungrounded design choices

---

## 0. Bottom line

No single proposal should become the final design unchanged.

- **Codex has the strongest public architecture:** native verification profiles, command provenance, oracle-integrity controls, one evidence-informed retry, Baton's existing control plane, file-backed evidence, native Windows, and no Ringer runtime dependency.
- **Grok has the strongest product framing:** Ringer as specialized proof-by-check labor, Baton as economic conductor; a clear quality-gate stack; strong work-shape routing heuristics; and the fastest path to a private Ringer trial.
- **Gemini has the strongest UX intent:** one operator surface, readable live status, explicit verification feedback, accessibility goals, and reuse of Baton's already-vendored HTMX and Chart.js.

The best tool is a synthesis, but the synthesis must be asymmetric:

1. Use **Codex's architecture and trust boundary** as the base.
2. Import **Grok's product language, task-shape decision table, and private-trial option**.
3. Import **Gemini's unified-UI principles and terminal legibility**, not its speculative full cockpit, invented data model, ThreadJob concurrency, or database assumptions.

The highest-leverage first release is not a Ringer adapter and not a Swarm Cockpit. It is a narrow native vertical slice:

```text
trusted verification profile
  -> one agentic task
  -> independent check
  -> durable evidence
  -> one informed retry
  -> existing Baton run detail
  -> preserved branch
```

Parallel batches and richer visualization should be designed only after that evidence lifecycle works on real runs.

---

## 1. Evaluation standard

The proposals are judged against the following requirements:

| Requirement | Why it matters |
|---|---|
| Public licensing/attribution safety | Baton is public and already overlaps with Ringer's product category |
| Command and filesystem safety | `/baton:go -Execute` can act without repeated human confirmation |
| Oracle integrity | A worker must not weaken or fabricate the test that passes its work |
| One control plane | Fleet, usage, cost, runs, routing, dashboard, and branches need an authority |
| Native Windows behavior | Baton runs natively on this machine; WSL cannot silently become the architecture |
| Durable code-delivery semantics | Successful edits must remain on reviewable branches/patches |
| Metric correctness | Task evidence, model quality, and run acceptance are different grains |
| Incremental delivery | The first slice must prove value without building a second platform |
| UI grounded in real data contracts | Templates cannot be designed around fields and states that do not exist |
| Accessibility and operational legibility | Live status must work for keyboards, assistive tech, reduced motion, narrow viewports, and non-TTY logs |

---

## 2. Comparative scorecard

| Dimension | Codex | Grok | Gemini | Best synthesis |
|---|---|---|---|---|
| Public runtime boundary | Native Baton; no Ringer dependency | Ringer as external Baton backend | Native Baton | Codex |
| Product explanation | Accurate but engineering-heavy | Clearest and most memorable | Clear visual framing | Grok language over Codex architecture |
| Security | Strongest: trusted profiles, argv, integrity grades | Weak: planner-generated shell checks | Recognizes argv/oracle risk but leaves command provenance vague | Codex |
| License posture | Conservative; adapter blocked pending permission | Acknowledges risk after recommending coupling | Calls risk “none” under “cleanroom,” which is overstated | Codex, with qualified legal review |
| Windows | Native design | WSL/private tool | Native design | Codex/Gemini |
| Time to private experiment | Slower | Fastest | Slower | Grok, but private and isolated |
| Time to safe public value | Narrow V1/V2 vertical slice | Broad adapter across many systems | Broad runner plus full UI | Codex |
| Parallelism | Deliberately deferred | Immediate through Ringer | Premature ThreadJob proposal | Separate post-verification design |
| Worktree durability | Preserved Baton branch | Ringer cleanup plus harvesting | Mostly follows Codex, little merge detail | Codex |
| Dashboard coherence | Reuse Baton; incremental | Keep Ringside beside Baton | Unified rich cockpit | Codex data boundary plus restrained Gemini UX |
| Implementation realism | Highest | Reasonable for private trial, weak for public integration | Lowest: UI assumes nonexistent task model and concurrency | Codex |
| Routing evidence | Capability-native, observe first | Import Ringer task-type rows | Model/task-type scoreboard and rookie board | Codex |
| Operator decision heuristics | Present but less concise | Best “when to use what” table | Good terminal narrative | Grok |
| Accessibility ambition | Requirements-level | Minimal | Strong intent, flawed sample implementation | Gemini intent, rewritten implementation |

---

## 3. Grok proposal: where it is better

The full issue-by-issue review remains in `codex-ringer-critique.md`. The following strengths should survive synthesis.

### 3.1 Best product thesis

Grok's statement that Ringer is specialized parallel labor with proof-by-check while Baton is the economic conductor gives the feature an immediately understandable place. Codex should adopt this language even though it rejects Ringer as a public runtime dependency.

### 3.2 Best overlap map

Grok clearly distinguishes:

- planning judgment from executable checking;
- independent batch labor from dependency-aware DAG work;
- model routing from nested process invocation;
- quality review from mechanical verification;
- swarm observability from project-level command-center visibility.

This prevents a “Ringer replaces Baton” misread better than either peer document.

### 3.3 Best operator routing heuristic

Grok's work-shape table is immediately useful:

- independent tasks with executable contracts -> verified batch;
- sequential dependencies -> Conductor DAG;
- plan critique -> Plan Gate;
- deliberation -> ensemble/council;
- specialty deterministic work -> tools registry;
- code edits needing merge ownership -> Baton's native worktree/merge path.

The final design should retain this as user-facing guidance, with “verified batch” referring to a future native Baton surface rather than automatically to Ringer.

### 3.4 Fastest experimental route

For a private, non-distributed comparison on this box, Grok's external-tool posture gets to real evidence fastest and preserves Ringside. That experiment can teach Baton what users value before Baton rebuilds any parallel UX.

### 3.5 Correct quality stack

Grok's Plan Gate -> executable check -> Acceptance Gate -> human merge sequence is right. Only the word “truth” needs correction to “evidence.”

---

## 4. Grok proposal: where it is worse

### 4.1 Blocking: it recommends coupling before resolving the license boundary

The document says “legal review before deep coupling” and then specifies a public command, adapter, registry entry, Conductor schema, bootstrap changes, dashboard link, and learning import. That is already deep product coupling.

**Correction:** public Ringer integration is blocked pending explicit licensor/legal clearance. A private manual trial is a separate, narrower decision.

### 4.2 Blocking: planner-produced shell checks become autonomous code execution

The proposed nested `ringer` block lets the planner write arbitrary shell commands and then runs them during `-Execute`. A worktree and `reversible` flag do not sandbox arbitrary commands.

**Correction:** planners may select trusted, base-revision verification profiles only. No planner-authored shell or argv command.

### 4.3 Blocking: it mistakes an executed check for an independent oracle

Workers may edit tests, fixtures, check helpers, or outputs that the check trusts. A passing check can still be self-graded.

**Correction:** freeze the contract outside the worker's writable area, hash protected oracle paths, constrain changed paths, and grade evidence strength.

### 4.4 Blocking: it creates two control planes

The adapter duplicates engine configuration, credentials, run stores, dashboards, learning systems, hooks, worktrees, identities, and cost policy. “Dual home in v1” does not establish authority.

**Correction:** native Baton functionality uses Baton's control plane. A private Ringer experiment remains wholly Ringer-owned and does not auto-import policy data.

### 4.5 Blocking: `tools.yaml` is semantically wrong

Ringer is a nested multi-worker executor with variable downstream cost, not one deterministic capability invocation. Marking the local Python wrapper `free` hides worker spend and usage.

**Correction:** no Ringer entry in `tools.yaml`, `fleet.yaml`, or a new registry.

### 4.6 Blocking: worktree harvesting is not branch preservation

Copying artifacts before Ringer deletes a passing worktree can save reports or patches, but does not preserve Baton's reviewable code branch. Multiple exported patches also require ordering and conflict handling.

**Correction:** exclude repo-edit tasks from the first private Ringer trial. Native Baton keeps its run branch.

### 4.7 Blocking: fail-open is incorrect for required labor

If Ringer is the planned executor and it is missing or fails to produce a result, the task must fail closed as infrastructure failure. Proceeding would claim success without labor.

### 4.8 High: nested manifests hide tasks from Baton

Nested Ringer tasks bypass Baton's DAG, per-task cost guard, usage governor, events, decisions, and routing. Ringer has no dependency graph inside a manifest.

### 4.9 High: the learning bridge mixes metric grains

Ringer attempt checks are not Baton run-level effective-cost outcomes. Free-form `task_type` is not Baton's `capability` taxonomy. Automatic import would corrupt meaning.

### 4.10 High: Windows/WSL is not designed

The proposal identifies the risk without resolving path ownership, worktrees, credentials, process cancellation, localhost behavior, or state roots.

---

## 5. Gemini proposal: where it is better

### 5.1 Correctly rejects the double-dashboard end state

Gemini is right that two permanent dashboards, two run histories, and two telemetry vocabularies impose cognitive cost. A public Baton feature should converge on Baton's dashboard.

This does not mean a temporary private Ringer experiment cannot use Ringside. It means Ringside should not become a permanent required surface of Baton.

### 5.2 Correctly chooses the native trust boundary

Gemini adopts argument-vector verification, oracle protection, native Windows, one fleet configuration, and no Ringer runtime. This is materially safer than Grok's backend recommendation.

### 5.3 Strong terminal narrative

The terminal example communicates:

- selected worker and cost tier;
- expected artifacts;
- verification profile and proof sentence;
- worker exit versus check outcome;
- raw failure evidence;
- retry and rescued-pass status.

That narrative should inform the CLI renderer after the data model exists.

### 5.4 Strong unified-dashboard goal

Gemini correctly identifies the operator questions the dashboard should answer:

- What is running?
- Which worker owns it?
- Is it laboring, verifying, retrying, passed, failed, or queued?
- What did the contract prove?
- Where is the bounded evidence?

Those questions are better than a generic event stream alone.

### 5.5 Correctly reuses available front-end primitives

HTMX and Chart.js are already vendored in Baton. The offline font and asset constraint also matches current dashboard practice.

### 5.6 Accessibility and responsive intent

Reduced motion, keyboard operation, offline rendering, and a narrow-viewport layout are necessary acceptance criteria. Grok and Codex underemphasize them.

---

## 6. Gemini proposal: blocking weaknesses

### G-B1. The UI is designed against a data model that does not exist

Gemini's template assumes:

- `run.id`, `run.name`, `run.branch`, `run.progress_pct`, `run.max_parallel`;
- `run.tasks` with task status, worker, model, proof, duration, retries, expected files, and raw log;
- `selected_task` and a stable selected-task query state.

Baton's actual `RunDetail` currently contains only `record` and `events`. `RunRecord` has no branch field or task collection. The router passes `detail`, not `run`. The reader loads `run.json` and `events.jsonl`; it does not load per-task evidence.

The HTML is therefore illustrative, not implementable. Treating it as a proposed file risks building the view before defining the backend contract.

**Correction:** first specify `TaskVerificationSummary`, task evidence files, reader behavior, status vocabulary, log-tail authorization, and route contracts. Only then design templates.

### G-B2. `Start-ThreadJob` is selected without an execution design

Gemini tries to pull parallelism forward by naming PowerShell ThreadJobs as a lightweight solution. The module exists on this box, but availability is not architecture.

Thread jobs run in separate runspaces inside the Baton PowerShell process. The proposal does not address:

- one worktree or output root per task;
- shared-state synchronization;
- provider invocation and prompt transport;
- cancellation and child process-tree termination;
- timeout escalation;
- stdout/stderr streaming and bounded logs;
- branch/patch preservation;
- dependency-ready waves;
- usage/budget races;
- process crashes taking down the host session;
- deterministic event ordering.

Calling it “lightweight” hides the hard parts. It also conflicts with the deliberate Codex sequencing: verify one task correctly before multiplying concurrency.

**Correction:** remove ThreadJobs from the design. Parallelism gets a separate process-supervisor and isolation spec after verified single-task evidence is proven.

### G-B3. It commits to a full cockpit before proving demand or concurrency

The proposed UI shows multiple simultaneous workers, live log streams, progress aggregation, a scoreboard, and a rookie-audition board. None of those are necessary to ship the first trusted verification loop, and true native swarm concurrency does not yet exist.

This front-loads the most visible and expensive layer before the engine has stable states. It invites schema churn and polished mockups backed by fake data.

**Correction:** extend the existing run detail with a verification summary first. A dedicated cockpit is conditional on real parallel runs and operator feedback.

### G-B4. The proposal invents a local database source of truth

Gemini recommends writing outcomes to “Baton's local database.” Baton's run dashboard is file-backed: `run.json`, `events.jsonl`, and reader functions over `$BATON_HOME/runs`.

There is no run database contract in the reviewed code. Adding one would require schema, migrations, concurrency, recovery, source-of-truth, backup, and reader changes.

**Correction:** task contracts and attempts remain files under the run directory. A database may later be a rebuildable read model, never the initial authority.

### G-B5. “Cleanroom” and “license risk none” are inaccurate

All three agents examined Ringer's guide, repository, implementation, templates, and UX. A new implementation can avoid copying protected code and assets, but it is not a formal clean-room process. Gemini's matrix marks licensing risk “none,” which is too absolute.

Recreating a close Ringside-like interface and describing it as a replacement also increases product/marketing sensitivity even if no Ringer code is called.

**Correction:** call it an independent Baton implementation based on generic requirements; do not copy Ringer source, templates, wording, assets, layout, or distinctive trade dress; retain legal review for public claims.

### G-B6. The sample UI contradicts its accessibility claims

The worker rows are clickable `<li>` elements with no button/link semantics, `tabindex`, keyboard activation, or focus style. Status is heavily color/icon-driven. The progress bar has no semantic `role="progressbar"` or accessible value. Live whole-panel replacement can disrupt focus and screen readers.

The CSS defines a pulsing animation but includes no `prefers-reduced-motion` rule, even though the QA section requires one.

**Correction:** use buttons or links, persistent focus, text status, semantic progress, scoped `aria-live="polite"`, reduced-motion CSS, and automated accessibility tests—not only a manual checklist.

### G-B7. Raw live logs are treated as ordinary UI content

Worker logs may contain untrusted model output, file paths, prompts, secrets, terminal control codes, or huge content. The proposed `raw_log` field is rendered in the main partial and refreshed repeatedly.

**Correction:** logs are separate validated tail endpoints, escaped as text, stripped of terminal control sequences, size-bounded, optionally redacted, collapsed by default, and polled only while the selected task is active.

---

## 7. Gemini proposal: high-severity weaknesses

### G-H1. It misrepresents Codex's scope

Gemini says Codex proposes rebuilding parallel worker pools, scoreboard visualizations, and catalog synchronization. Codex explicitly defers parallel batches, does not propose an OpenRouter catalog, and separates observe-only routing evidence from run effective cost.

The claimed “NIH tax” is therefore inflated. V1/V2 are a verification runner and retry integration, not a Ringer clone.

### G-H2. It falsely says Codex missed Ringer worktree deletion

`codex-ringer.md` explicitly records Ringer's passing-worktree cleanup, contrasts it with Baton's preserved branch, and specifies durable patches/branches for any future repo batch. Gemini's criticism is factually wrong.

### G-H3. It uses invalid Baton vocabulary

The CLI example assigns Grok `cost_tier: standard`. Baton's vocabulary is exactly `local | free | paid`. Examples are contracts; invalid vocabulary teaches the wrong system.

### G-H4. It reintroduces Ringer's `task_type` taxonomy

The scoreboard groups by “model and task type,” contradicting the recommendation to keep model selection in Baton's unified control plane. Baton already routes by `capability`.

**Correction:** aggregate by Baton capability and worker, with evidence grade, sample count, confidence, and infrastructure-error rate.

### G-H5. The Rookie Audit Board is unrelated scope with write risk

Fetching an OpenRouter catalog, ranking untested models, and offering a one-click “Audition” action adds network dependency, credentials, cost variability, model identity, safety confirmation, and a mutating run action. It is not needed for native verification.

**Correction:** remove it. Model discovery/audition requires a separate research and product decision.

### G-H6. The template ignores existing dashboard conventions

The actual run detail receives `detail.record` and `detail.events`, polls every five seconds, and uses existing tokens. Gemini creates a second `:root` palette whose values duplicate or conflict with the current design system. It proposes a separate `/swarm` page instead of first extending the existing run detail.

**Correction:** reuse `--bg-*`, `--accent-*`, radius, font, and transition variables already present. Extend the current detail view before adding navigation.

### G-H7. Whole-cockpit polling is operationally poor

Replacing the entire cockpit every two seconds can reset focus, selection, expanded state, log scroll, and screen-reader context. Re-rendering bounded logs with every summary poll also wastes CPU and bandwidth.

**Correction:** poll the small task summary at the established five-second cadence. Poll the selected active task's log tail separately and stop when terminal. Preserve selection client-side or in the URL without swapping the whole region.

### G-H8. Terminal “pulsing” and color assumptions are not robust

ANSI text cannot pulse without a redraw loop. Continuous redraw harms logs and pipes. Color and Unicode status glyphs need TTY detection, `NO_COLOR`, non-interactive output, terminal-width truncation, and a stable `--json` mode.

**Correction:** emit append-only status lines by default; enable a compact live renderer only on an interactive TTY.

### G-H9. The progress model is underspecified

“3/4 tasks passed” does not say how failed, skipped, blocked, verifying, retrying, or unverified tasks affect progress. Dependency-aware tasks also make percentage-of-count misleading.

**Correction:** define terminal and active states first. Display counts by state; use a progress bar only when the denominator and completion semantics are honest.

### G-H10. Manual QA is not enough

The design needs automated tests for reader parsing, path traversal, log escaping, status mapping, template rendering, HTMX endpoints, focusable controls, and reduced-motion CSS. A manual 390px check cannot protect these contracts.

---

## 8. What both peers miss

### 8.1 The final design needs an explicit task status machine

Neither peer fully defines the state transitions that the engine, events, CLI, and UI share.

Recommended states:

```text
queued
  -> laboring
  -> verifying
  -> passed
  -> retrying -> laboring -> verifying -> passed | failed

queued/laboring/verifying/retrying
  -> infrastructure-error
  -> scope-violation
  -> cancelled

legacy task without profile
  -> unverified
```

Each state needs a terminal/non-terminal classification and an event mapping. UI work should not start before this is stable.

### 8.2 Evidence should be durable but not copied everywhere

The source of truth should be small run files with paths to bounded output. Events should carry summaries, not raw logs. The dashboard should derive views from the same files.

### 8.3 Infrastructure failure must be separated from worker quality

Missing executables, WSL failures, rate limits, timeouts caused by the harness, and log parse failures must not reduce a model's quality score.

### 8.4 Verification quality needs provenance

The UI and routing analysis should show whether evidence was strong, bounded, weak, or invalid. A green check without oracle provenance invites false confidence.

### 8.5 UI actions need economic and external-write gates

Any “retry,” “audition,” “run again,” “apply,” or “open external tool” action must state cost tier, usage availability, branch/output target, and whether it mutates external state.

---

## 9. Recommended final architecture

### 9.1 Public architecture

Use `codex-ringer.md` as the backend baseline with these refinements from the peers:

- adopt Grok's concise product framing and work-shape table;
- add a TTY-aware CLI renderer informed by Gemini's narrative;
- add minimal verification summaries to the existing run detail in the same slice as durable evidence;
- promote accessibility and offline behavior to automated acceptance criteria;
- keep a later rich cockpit conditional on real concurrent usage.

Do not:

- invoke or package Ringer;
- add Ringer to a Baton registry;
- add planner-authored executable commands;
- use ThreadJobs as an unreviewed concurrency shortcut;
- create a run database as the first authority;
- recreate Ringside's layout/assets/wording;
- add OpenRouter catalog/audition scope;
- change routing weights in the first release.

### 9.2 Minimal data contract for UI

After V2, add a reader model grounded in task evidence:

```text
TaskVerificationSummary
  id
  description
  capability
  worker
  status
  attempt_count
  first_try
  verification_grade
  proves
  duration_ms
  evidence_path
  output_excerpt
```

`output_excerpt` is already escaped, control-character-stripped, and bounded by the reader. Raw output is fetched only through a validated task evidence endpoint.

### 9.3 UI progression

#### UI-0 — CLI and file artifacts

- append-only TTY/non-TTY-safe status lines;
- `--json` output for automation;
- proof sentence, attempt count, grade, and evidence paths in `report.md`.

#### UI-1 — existing run detail extension

- task verification list beneath the current timeline;
- text states plus restrained icons;
- proof sentence and evidence grade;
- selected-task bounded output on demand;
- five-second summary polling using existing HTMX patterns.

#### UI-2 — verified-task insights

- capability × worker table;
- first-try/rescued counts;
- sample count, confidence, evidence-grade mix, and infrastructure errors;
- observe-only, no automatic routing change.

#### UI-3 — conditional cockpit

Only after a separate parallel executor ships and live use shows the existing detail view is insufficient. Start with information architecture and usability testing, not a copied Ringside layout.

### 9.4 Corrected implementation sequence

| Slice | Deliverable | Reason |
|---|---|---|
| 0 | Product/license decision | Prevent accidental Ringer dependency or copied expression |
| 1 | Trusted verification profiles + pure runner | Establish safe oracle execution |
| 2 | Agentic executor integration + one retry + state machine | Prove value on one task |
| 3 | Report/CLI + minimal existing run-detail UI | Make evidence legible without speculative cockpit |
| 4 | Observe-only capability evidence | Validate metrics before routing changes |
| 5 | Separate parallel execution/isolation design | Solve concurrency honestly |
| 6 | Conditional rich cockpit | Build only for real multi-worker operations |
| X | Optional private pinned Ringer experiment | Product research, not public runtime architecture |

---

## 10. Specific recommendations to Grok

1. Change the thesis from “Ringer becomes a Baton backend” to “Ringer demonstrates a native Baton verification lifecycle; direct use is an optional private experiment.”
2. Put license/product eligibility before installation or adapter design.
3. Delete public `/baton:ringer`, `tools.yaml`, nested Conductor manifest, and automatic scoreboard-import recommendations.
4. Replace raw shell checks with trusted verification profiles.
5. Add oracle integrity, allowed paths, evidence grades, and infrastructure-error semantics.
6. Keep the gate stack and task-shape heuristic.
7. Restrict a private Ringer trial to read-only/artifact workloads first.
8. Pin upstream version and keep Ringer fully authoritative for its experimental run.
9. Do not call `install-agent` or modify Baton hooks.
10. Do not describe missing required labor as fail-open.

---

## 11. Specific recommendations to Gemini

1. Keep the single-dashboard principle, CLI narrative, accessibility goals, and offline requirements.
2. Remove “cleanroom” and “license risk none” language.
3. Correct the factual claim that Codex missed Ringer worktree cleanup.
4. Correct `cost_tier: standard` to Baton's actual vocabulary.
5. Replace `task_type` with Baton `capability` in all scoreboards.
6. Remove ThreadJobs from the architectural decision; concurrency needs its own design.
7. Remove the Rookie Audit Board and OpenRouter catalog from this scope.
8. Do not invent a local run database; retain file-backed source truth.
9. Define the task status/evidence/read model before HTML or CSS.
10. Extend the existing run detail before creating `/swarm` navigation.
11. Reuse current CSS tokens rather than introducing a second `:root` system.
12. Replace clickable `<li>` elements with semantic controls and implement reduced motion in code, not only QA prose.
13. Split summary polling from bounded log-tail polling.
14. Add automated accessibility, escaping, traversal, and route tests.
15. Treat the full cockpit as conditional future work, not a decision bundled with native verification.

---

## 12. Decision recommendation

When the user approves a binding direction, the Grimdex decision should be narrower than Gemini's proposed title.

Recommended title:

> Native task verification profiles before parallel swarm execution

Recommended chosen statement:

> Baton will add trusted, base-revision verification profiles, independent task checking, durable attempt evidence, and at most one failure-informed retry to the existing agentic executor. Baton remains the only public control plane and preserves its run branch, capability taxonomy, file-backed state, gates, and human merge boundary. Parallel execution and a rich cockpit are separate follow-on decisions. Ringer remains cited prior art and an optional private experiment unless explicitly licensed for integration.

Alternatives to record:

- public Ringer backend: rejected pending license and control-plane resolution;
- ThreadJob swarm plus cockpit now: rejected as concurrency/UI before contract and isolation;
- proof-by-diff only: rejected because a changed tree does not prove required behavior;
- full Ringside recreation: deferred; first extend existing run detail from real evidence.

---

## 13. Final judgment

### Best parts to keep

- **From Grok:** the sentence that explains the products, the overlap map, the gate stack, the work-shape routing heuristic, and the private experiment's speed.
- **From Gemini:** one public dashboard, explicit verification feedback, high-quality terminal narration, accessible/responsive/offline acceptance criteria, and reuse of existing HTMX/Chart.js.
- **From Codex:** the public runtime boundary, trusted verification profiles, command provenance, oracle integrity, durable evidence, native capability taxonomy, correct metric grains, native Windows, and incremental slice order.

### Most dangerous ideas to reject

- **From Grok:** a public Ringer backend with model-authored shell checks, dual control planes, misleading tool cost, disappearing code worktrees, and fail-open required labor.
- **From Gemini:** ThreadJob parallelism as a shortcut, a full cockpit backed by invented fields, an unplanned database, raw live-log rendering, one-click model auditions, duplicated CSS tokens, and the claim that this is cleanroom/no-license-risk work.

The best Baton tool is not “Ringer inside Baton” and not “Ringside rebuilt immediately.” It is Baton closing its labor-trust gap first, then earning parallelism and richer visualization from real, durable evidence.
