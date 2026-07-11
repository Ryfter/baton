# Codex critique of `grok-ringer.md`

**Reviewer:** Codex
**Date:** 2026-07-10
**Artifact reviewed:** [`grok-ringer.md`](grok-ringer.md) at Baton `db16454`
**Comparison baseline:** [`codex-ringer.md`](codex-ringer.md)
**Purpose:** Identify what Grok understood better, what is unsafe or underspecified, and what a synthesized Baton design should keep or reject

---

## 0. Overall verdict

Grok's document is a strong product-positioning memo and a weak implementation-safety specification.

Its central separation—**Baton as economic conductor, Ringer as proof-by-check parallel labor**—is clear, memorable, and mostly correct at the conceptual layer. Its overlap map, quality-gate stack, operator routing heuristic, worktree warning, phased delivery, and explicit “do not replace Baton” boundaries are all valuable.

Its recommended architecture nevertheless commits too early to the most dangerous option: making Ringer an external Baton execution backend. That conclusion is not earned by the analysis. The document notices the license, Windows/WSL, configuration drift, cost double-counting, and worktree risks, but treats them as follow-up mitigations rather than possible disqualifiers. More seriously, it misses two trust problems at the heart of the feature:

1. Baton would be executing shell checks authored or selected by a model during a full-auto run.
2. A worker may be able to modify or spoof the oracle that declares its work correct.

Those are blocking design flaws, not implementation details.

**Recommendation:** Keep Grok's product framing and gate-layer explanation. Reject its public adapter/backend recommendation. Build a Baton-native, trusted verification-profile layer first. Treat direct Ringer use as an optional private experiment unless the licensor explicitly clears public integration.

---

## 1. Where Grok is better

### 1.1 The one-sentence product framing is excellent

> “Ringer is a specialized parallel labor executor with proof-by-check; Baton is the economic conductor.”

This is sharper than the opening of the Codex spec. It establishes roles before implementation details and prevents the most obvious “replace Baton with Ringer” mistake.

Keep this framing in any synthesis, with one correction: Ringer is a **reference or private external executor**, not automatically a Baton backend.

### 1.2 The overlap map is highly legible

Grok's concern-by-concern comparison makes the complementarity obvious:

- Ringer is stronger at independent fan-out and executable checks.
- Baton is stronger at planning, research, economic policy, projects, and judgment gates.
- The dashboard and learning systems overlap but operate at different grains.

This is an effective product-design artifact. The Codex spec is more rigorous about trust and ownership, but Grok's table explains the value proposition faster.

### 1.3 The quality-layer stack is right

Grok correctly separates:

```text
Plan Gate -> executable check -> Acceptance Gate -> human merge
```

That is one of the best parts of the document. It prevents the common mistake of treating a passing test as a complete product-quality judgment.

The language should change from “mechanical truth” to “mechanical evidence,” but the lifecycle placement is sound.

### 1.4 The routing heuristic is useful to an operator

The distinction among independent checkable batches, sequential DAGs, repo merge work, deliberation, plan review, and specialty tools is practical. It gives a human or agent an immediate decision rule.

The Codex design intentionally postpones a new batch surface. Grok is better at describing the eventual user experience once such a surface exists.

### 1.5 It notices the Ringer worktree deletion footgun

Grok explicitly calls out that passing Ringer worktrees are removed and that durable deliverables must be exported. This is essential and easily missed from the marketing page.

The proposed mitigation is incomplete for code changes, but noticing the failure mode is a real strength.

### 1.6 It correctly rejects registering Ringer as a normal fleet provider

Ringer is not a model that accepts one prompt. Treating it as one would erase its manifest, verification, retry, and per-task observability semantics. Grok is correct here.

### 1.7 Its delivery slices and success criteria are tangible

The R0–R5 structure makes the proposal reviewable. It names command surfaces, files, artifacts, dashboard behavior, and completion tests. Even where the architecture is wrong, the document gives a builder something concrete to challenge.

### 1.8 For a private experiment, Grok's approach is faster

If the goal is only “try Ringer on Kevin's machine this week,” Grok's thin adapter or even a manual external run gets to an answer faster than implementing Baton's native verifier. It also preserves Ringside and Ringer's upstream templates.

That speed advantage is real. It just does not justify making the experiment the public product architecture.

---

## 2. Blocking weaknesses

### B1. The license risk is acknowledged but architecturally ignored

**Grok sections:** §1, §4.3, §5 R0, §7, §8, §10
**Severity:** Blocking for any public Baton integration

Grok says “legal review before deep coupling” and then recommends a public tool/spawner backend, command, registry entry, bootstrap changes, Conductor schema, scoreboard bridge, and dashboard link. That is already deep product coupling.

Ringer uses PolyForm Shield. Its noncompete language is broad: products may compete across different interfaces and platforms, and even free products may compete. Baton already overlaps in AI-agent orchestration, worker routing, evaluation, and observability. An adapter that makes Ringer a Baton feature may be riskier than merely using Ringer internally.

Placing a “legal skim” as step 6 of R0—after clone, configuration, engine wiring, and demo—is backwards. Product/legal eligibility is the first gate.

**Recommendation:** Replace the public adapter recommendation with a native Baton verification design. If a Ringer bridge remains, mark it private, separately installed, non-distributed, and blocked from marketing or bootstrap until the licensor grants permission. This is an engineering risk conclusion, not legal advice.

### B2. The proposed Conductor schema lets a planner author arbitrary shell execution

**Grok sections:** §4.3, §5 R2
**Severity:** Blocking security issue

Grok proposes nesting Ringer tasks containing raw `check` strings inside planner-produced `plan.json`, then executing them automatically. Ringer's `check` is a shell command. Baton `/baton:go -Execute` is specifically designed to continue without asking except at budget/destructive guards.

A model-authored shell check can read or write outside the worktree, invoke networked tools, delete files, alter credentials, publish state, or evade simple string filters. The task's `reversible` boolean does not make arbitrary shell content safe.

This is not solved by running Ringer in WSL or a worktree. A working directory is not an OS sandbox.

**Recommendation:** The planner may select only a named verification profile frozen from trusted project configuration. The executable form should be an argument vector, not a shell string. Inline checks require an explicit user-authorized run and must not be the autonomous default.

### B3. “The check is truth” ignores oracle tampering

**Grok sections:** §2, §3, §4.5, §9
**Severity:** Blocking trust-model flaw

Grok repeatedly equates Ringer checks with mechanical truth. Executing a check is stronger than reading worker prose, but a worker can sometimes edit the tests, fixtures, or helper scripts the check invokes. It may also satisfy a weak proxy while violating the actual requirement.

Examples:

- change the assertion instead of the implementation;
- replace a verifier helper with `exit 0`;
- print an expected marker without doing the operation;
- write outside owned paths while a focused test still passes;
- modify a fixture so the edge case disappears.

Ringer's linter warns about some weak checks but does not make every oracle immutable. Grok does not discuss this.

**Recommendation:** Add protected oracle paths, task allowed paths, base-revision contract freezing, and deterministic evidence grades. Call the result evidence, not truth. Only high-integrity evidence should influence routing.

### B4. The proposed backend creates a second control plane

**Grok sections:** §4.2–§4.6, §5 R1–R5
**Severity:** Blocking product-coherence issue unless explicitly accepted

The proposal would give Baton:

- `fleet.yaml` plus Ringer engine TOML;
- `$BATON_HOME/runs` plus `~/.ringer` state;
- Baton routing/effective cost plus Ringer models/catalog;
- Baton dashboard plus Ringside;
- Baton hooks/coach plus Ringer install-agent hooks;
- Baton worktrees/branches plus Ringer worktrees/cleanup;
- Baton budget/usage policy outside a nested executor that launches its own workers.

Grok labels the duplication “dual-home v1” and “keep both,” but does not define which system is authoritative when they disagree. That is not composition by itself; it is duplicated governance.

**Recommendation:** Reuse Baton's native control plane for public functionality. For a private Ringer experiment, state that Ringer is authoritative for its run and Baton imports nothing automatically.

### B5. `tools.yaml` is the wrong registry and its cost claim is misleading

**Grok section:** §4.3
**Severity:** Blocking schema/semantics mismatch for R1

Baton's current `references/tools.yaml` describes a single non-LLM callable capability with fields such as `capability`, `kind`, and `command_template`. Ringer is a nested multi-worker executor with a manifest, its own engine selection, and variable downstream spend.

Marking Ringer `cost_tier: free` because the Python coordinator is local would mislead Baton's economic router. The coordinator may launch paid, subscription-limited, or usage-exhausted workers. Cost belongs to the nested tasks, not the wrapper binary.

The proposed alternative `labor-backends.yaml` invents a new registry before proving that more than one backend needs it.

**Recommendation:** Do not register Ringer in `tools.yaml`. Do not add a labor-backend abstraction for a single optional experiment. Native verification requires no new registry.

### B6. Ringer worktree semantics do not preserve Baton's code-delivery contract

**Grok sections:** §4.4, §4.8, §5 R0–R2
**Severity:** Blocking for code-edit labor

Grok focuses on harvesting expected files before Ringer deletes a passing worktree. That is enough for reports, assets, and exported patches. It is not enough for Baton's promise that agentic labor lands on a durable `baton/run-<id>` branch for human review and merge.

For code tasks, “confirm harvested paths exist” can produce PASS while the actual repo edits have disappeared. A copied diff is not the same as a preserved branch, and applying several independent patches introduces ordering/conflict semantics absent from the proposal.

**Recommendation:** Exclude repo-edit tasks from an initial private bridge. Use it only for artifact/review/research batches, or explicitly export and validate patches with a separate merge design. Public Baton code labor should keep its native persistent branch.

### B7. Fail-open is wrong for a required labor backend

**Grok section:** §5 R2
**Severity:** Blocking correctness issue

Grok says a missing Ringer binary should “fail-open.” Fail-open is appropriate for advisory reviewers such as an under-staffed Plan Gate. It is not appropriate when the plan explicitly requires Ringer to perform labor. Proceeding without the executor can mark a DAG as successful without doing the work.

**Recommendation:** Missing executable, invalid manifest, unavailable WSL, state-parse failure, or missing result contract must fail the task closed with a clear infrastructure verdict. Infrastructure failures should not penalize model quality.

---

## 3. High-severity weaknesses

### H1. No pinned upstream contract

The proposal depends on `ringer.py` CLI flags, stdout, state paths, JSON fields, and eval rows, but it never pins a Ringer commit/version or identifies a stable machine-readable integration contract. The researched repository was at `3f7ca5c`; the guide and main branch can change independently.

**Recommendation:** A private bridge must pin a tested commit, record it in every run, define the exact files/fields consumed, reject unsupported versions, and have contract fixtures. A public adapter would also need an upstream compatibility policy.

### H2. Windows/WSL is a named risk, not a design

Grok offers “prefer WSL clone or port validation” but does not resolve:

- Windows Baton paths versus WSL paths;
- Git repo ownership and worktree operations across filesystems;
- `$BATON_HOME` versus WSL home;
- browser launch and localhost visibility;
- environment and identity propagation;
- Codex/Grok credentials installed on one side only;
- process cancellation and cleanup across `wsl.exe`.

**Recommendation:** Do not make WSL part of Baton's public architecture. For a private spike, choose one repo location and one process owner, prohibit cross-filesystem worktrees, and write explicit start/stop/path translation acceptance tests.

### H3. A nested Ringer manifest hides work from Baton's DAG

Grok's proposed `ringer` task contains its own task list. Those nested tasks become invisible to Baton's dependency resolver, per-task budget guard, usage governor, events, decisions, cost shares, and Plan Gate task reasoning.

Ringer itself has no internal dependency graph, so the nested structure can represent only a flat island inside the Baton DAG. If one nested task depends on another, the proposed schema cannot express it honestly.

**Recommendation:** Keep each logical task visible in Baton's native plan. Add verification to tasks first. Later, run independent ready sets concurrently with explicit isolation.

### H4. The learning bridge mixes incompatible grains

Grok proposes importing Ringer eval rows into “Baton effective-cost / routing journal as advisory rows.” These are different metrics:

- Ringer rows are per attempt/task, organized by free-form task type and executed-check verdict.
- Baton effective cost is per accepted run, based on final Acceptance Gate quality and worker cost shares.
- Baton routing quality is per capability/candidate with human, judge, and heuristic provenance.

Writing task checks into `effective-cost.json` would silently change the metric. Mapping `task_type` to `capability` is not merely a lookup problem; the categories have different semantics.

**Recommendation:** Keep Ringer data separate in any experiment. Native Baton verification should use Baton's existing capability at task level. Feed only strong evidence into routing after an observe-only period; keep final acceptance as the effective-cost quality numerator.

### H5. First-try pass rate is treated as more causal than it is

First-try pass is a useful operational measure, but it also reflects prompt specificity, task difficulty, check strictness, harness version, environment, retry policy, and model. Ringer's current “proven” threshold of three tasks and 0.67 is a lightweight heuristic.

Grok repeats the scoreboard as if it directly answers model routing.

**Recommendation:** Always show sample count, confidence, evidence grade, infrastructure errors, and task/capability scope. Do not promote a worker based on a few weak or heterogeneous checks.

### H6. Dual engine/provider configuration has no reconciliation rule

Grok says fleet rows are the economic view and Ringer engines the process view, then suggests generating Ringer blocks later. This leaves model names, executable paths, sandbox flags, stdin behavior, credentials, availability, cost tiers, and usage exhaustion capable of drifting independently.

Generating one config from the other is not trivial: Ringer and Baton have different invocation placeholders and policy semantics.

**Recommendation:** Avoid dual registration by choosing native Baton execution. In a private bridge, Ringer owns its engines entirely; Baton does not pretend to route inside the nested run.

### H7. The Plan Gate extension is scope creep on an unbuilt feature

d080's Plan Gate code is not yet implemented. Grok proposes expanding it to review Ringer manifests and adding `check-quality` areas before the base gate has live evidence.

**Recommendation:** Build and validate d080 as specified. Later, add verification review to Baton's native task schema in a separate decision. Do not make Plan Gate understand an external product's manifest.

### H8. Supply-chain and executable trust are absent

The design proposes cloning and invoking a mutable public repository, configuring worker executables, and perhaps installing agent hooks, but does not specify:

- commit pinning and update policy;
- checksum/source verification;
- who may modify Ringer config;
- executable allowlists;
- logging/redaction boundaries;
- rollback and uninstall;
- behavior if upstream adds new network or filesystem actions.

**Recommendation:** Treat external Ringer as untrusted executable software. A private experiment needs an explicit pinned install and no automatic update/install-agent behavior.

### H9. Ringer's `install-agent` can conflict with Baton governance

Both products want to nudge the orchestrator toward their own workflow. Installing Ringer's Claude skill and hooks alongside Baton's plugin hooks can create duplicate or contradictory advice, settings edits, and debugging ambiguity. Grok notes multi-harness limitations but not collision handling.

**Recommendation:** Do not call `ringer.py install-agent` as part of Baton setup. In a private trial, invoke Ringer explicitly and leave agent settings untouched.

### H10. OpenCode/OpenRouter cost mapping is inaccurate

Grok loosely maps the OpenCode lane to a free-tier class. OpenRouter models may be free, paid, promotional, or variable, and credentials/prepaid balance live outside Baton. A single engine can launch models across cost tiers.

**Recommendation:** Do not assign one Baton tier to the OpenCode engine. If Baton later supports it natively, cost belongs to the selected model and catalog snapshot, not the harness.

---

## 4. Medium-severity gaps

### M1. Partial-success semantics are posed as a question instead of designed

“All must pass” is a safe default, but Ringer can produce useful partial artifacts. The adapter needs explicit terminal states such as `completed`, `partial`, `failed`, and `infrastructure-error`, plus rules for whether downstream Baton tasks may consume partial output.

For code DAG execution, downstream tasks should not proceed from an incomplete required batch.

### M2. Ringer run identity/state joining is underspecified

Setting `--identity baton/<run-id>` helps display lineage but does not uniquely resolve the Ringer state file or result row when runs overlap. The proposal alternates among copies, symlinks, pointers, and eval excerpts without a contract for discovering the actual Ringer run id.

### M3. Dashboard coexistence needs lifecycle semantics

“Open Ringside” requires a known live port/process and a safe URL. The proposal does not say what Baton shows when Ringside is stopped, running in WSL, on a different port, or serving a removed run.

### M4. Artifact copying can duplicate sensitive logs

Copying Ringer state/eval excerpts into `$BATON_HOME` may duplicate raw prompts, worker output, paths, or secrets. The proposal prefers copies without a retention/redaction policy.

### M5. The model/harness attribution may not be exact

Ringer depends on manifest fields, engine defaults, command inspection, and token regexes. Plan-billed Grok has no token count in the current config. The proposed cost bridge assumes more exact telemetry than all lanes provide.

### M6. No explicit update, disable, or uninstall story

An optional backend needs readiness checks, version status, disable behavior, config migration, state retention, and uninstall. R0 covers install/demo only.

### M7. Testing is not specified deeply enough

“Mock ringer.py” is necessary but insufficient. A bridge would need:

- pinned CLI contract fixtures;
- non-zero/timeout/partial-result tests;
- malformed and changing state JSON;
- concurrent run-id tests;
- WSL path/process cancellation tests;
- worker process-tree kill tests;
- cost/identity/model-attribution tests;
- license/notice packaging audit;
- an opt-in live smoke at the pinned upstream revision.

### M8. The proposal expands too many surfaces at once

R1 adds a library, CLI, command, registry, bootstrap, run wrapping, and models passthrough. R2 changes the planner schema and Conductor. R3 changes learning. R4 changes coaching/hooks. R5 changes the dashboard. This is a broad integration before the core value—does executable verification improve Baton labor?—is isolated and proven.

---

## 5. Direct comparison

| Design question | Grok take | Codex take | Better answer |
|---|---|---|---|
| Product framing | Ringer executor under Baton conductor | Ringer proves a missing Baton verification lifecycle | Grok is clearer; Codex is safer about the runtime boundary |
| Fastest private trial | Thin external adapter/manual setup | Optional private experiment after product boundary | Grok, if explicitly private and disposable |
| Public architecture | Ship an external Ringer backend | Native verification profiles; no Ringer dependency | Codex |
| Verification command | Preserve Ringer shell checks | Trusted base-revision profile, argv, no planner-authored command | Codex |
| Oracle integrity | Not addressed | Protected paths, allowed paths, frozen contract, evidence grade | Codex |
| Worktree outcome | Harvest deliverables before deletion | Preserve Baton branch; design repo batch separately | Codex for code, Grok adequate for artifact batches |
| Gate layering | Excellent explicit stack | Same stack with evidence terminology | Grok presentation; Codex precision |
| Parallelism | Ringer backend early | Verification first, concurrency later | Codex for product sequencing; Grok for eventual UX |
| Learning | Import Ringer task rows into Baton systems | Use Baton capability evidence; keep run effective cost distinct | Codex |
| Dashboard | Keep Ringside, add link | Reuse Baton events/dashboard | Grok is cheaper privately; Codex is coherent publicly |
| Windows | WSL spike | Native Baton path; WSL only private experiment | Codex |
| Licensing | Risk to review during adoption | Public adapter blocked pending permission | Codex |
| Operator heuristics | Strong selection table | More architectural than conversational | Grok |
| Scope control | R0–R5 across many systems | V0–V4 vertical evidence slices | Codex |

---

## 6. Recommended redline of Grok's proposal

### Keep with small edits

- §1 factual inventory, while replacing “mechanical truth” with “executable evidence.”
- §2 Baton contrast.
- §3 overlap map.
- §4.5 gate stack.
- §4.7 work-shape heuristic as a description of the eventual system.
- §4.8 worktree warning, expanded to cover durable patches/branches.
- §7 “do not replace” table.
- §9 tangible user success criteria, rewritten for native verification.

### Replace

#### Replace §0 thesis

Current conclusion:

> Ringer should become a Baton tool / labor backend.

Recommended conclusion:

> Ringer demonstrates the verification and evidence loop Baton should add natively. Direct Ringer use remains an optional private experiment unless the licensor clears public integration.

#### Replace §4.1 architecture

Keep the lifecycle diagram but put **Baton Verification Runner** after native labor. Show Ringer only as a dotted, private sidecar used for comparative experiments.

#### Delete public §4.3 registry/backend recommendation

Do not add Ringer to `tools.yaml`, `fleet.yaml`, or a new registry. Do not add `/baton:ringer` to the public plugin yet.

#### Replace §4.4 run join

For native verification, use Baton's existing run tree and add per-task contract/attempt/evidence files. For a private Ringer trial, store only a user-provided pointer and pinned version; do not copy raw eval logs by default.

#### Replace §4.6 dual registration

No dual config in the public path. In a private trial, Ringer owns its engine config and Baton does not claim economic control over nested workers.

#### Replace §5 build order

Use:

1. product/license decision;
2. pure verification profile/runner;
3. executor integration and one retry;
4. dashboard/report evidence;
5. observe-only routing analysis;
6. separate parallel-batch design;
7. optional private Ringer comparison.

#### Defer §6 Plan Gate extension

Do not expand d080 until the base Plan Gate is implemented and live-tested.

---

## 7. If Kevin still wants a private Ringer bridge

The safest narrow experiment is not Grok's R1–R5. It is:

1. User installs Ringer separately in WSL and accepts its license directly.
2. Pin the clone to a tested commit and disable automatic updating.
3. Do not run `install-agent`.
4. Do not register Ringer in Baton config.
5. Start with read-only/artifact tasks: reviews, research reports, bakeoffs, or generated assets.
6. Exclude repo-edit tasks until durable patch/branch semantics are designed.
7. Invoke Ringer explicitly outside `/baton:go`; no full-auto planner-generated manifest.
8. Let Ringer own its workers, budget risk, state, and Ringside.
9. Let Baton record only a manual note/pointer after the run.
10. Do not import Ringer eval rows into routing or effective cost.
11. Compare operator time, first-try pass, retry usefulness, and artifact quality against a native Baton run.
12. Use the evidence to decide whether Baton's native V1–V3 should copy the *general behavior*, never the source or templates.

This produces useful product evidence without pretending the integration contract is solved.

---

## 8. Synthesized recommendation

The best combined direction takes Grok's product clarity and Codex's trust boundary:

```text
Baton remains the only public conductor and control plane.

Ringer contributes validated product lessons:
  - every labor task needs executable evidence;
  - one failure-informed retry is valuable;
  - first-try versus rescued pass should be measured;
  - independent, checkable batches deserve a first-class future UX.

Baton implements those lessons natively with:
  - trusted verification profiles selected by plans;
  - argument-vector execution, no planner-authored shell;
  - protected oracle and allowed-path integrity;
  - durable per-attempt evidence;
  - native capability and run-level metric separation;
  - preserved branches and existing gates.

Ringer itself remains:
  - cited prior art;
  - an optional private comparison tool;
  - excluded from public runtime/packaging unless explicitly licensed.
```

That direction gets the important product improvement without paying for two orchestrators, two routers, two run stores, two dashboards, and an unresolved license boundary.

---

## 9. Final judgment on Grok's work

Grok's take is better at explaining **why a user would want this**. Codex's take is better at specifying **what can safely and coherently ship**.

The Grok document should not be discarded. Its framing, overlap map, gate stack, task-shape heuristic, and concrete success criteria belong in the final synthesis. But its primary recommendation—publicly composing Baton around Ringer as a labor backend—should be reversed unless both the legal and technical control-plane issues are explicitly resolved.

The deepest correction is conceptual:

> A process that runs a check is not automatically trustworthy. The check must be authorized, independent enough to resist self-grading, scoped, durable, and interpreted at the correct metric grain.

That is the standard the final Baton tool should meet.
