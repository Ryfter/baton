# Codex view: what Baton should learn from Ringer

**Author:** Codex
**Date:** 2026-07-10
**Status:** Independent product/architecture specification; no implementation is authorized by this document
**Sources:** [Unlock AI Ringer guide](https://unlock-ai.natebjones.com/guides/ringer) · [NateBJones-Projects/ringer](https://github.com/NateBJones-Projects/ringer) at `3f7ca5c` · Ringer `README.md`, `config.sample.toml`, `ringer.py`, representative templates, and `LICENSE.md` · Baton master at `db16454` · Baton decisions d056, d077, d078, and d080

---

## 0. Executive decision

Ringer validates an important missing layer in Baton: **a worker should not pass because it exits successfully, writes a diff, or says it is done; it should pass because an independent, executable contract produces evidence.** Ringer also demonstrates the value of one failure-informed retry and first-try pass-rate telemetry.

The public Baton project should **adopt those general system properties natively**. It should not vendor Ringer, copy its implementation, register it as a fleet provider, or ship a Baton-to-Ringer execution adapter without explicit legal clearance from Ringer's licensor.

The recommended design is therefore:

1. Add an optional, Baton-native **verification profile** to Conductor tasks; the executable contract comes from trusted project configuration, not free-form planner output.
2. Execute the contract independently after agentic labor.
3. Retry a failed task at most once with bounded raw verification evidence.
4. Record attempt-level, capability-native evidence for Baton's existing router and dashboard.
5. Preserve Baton's Plan Gate, budget/usage controls, acceptance review, branch-preserving worktrees, and human merge boundary.
6. Design parallel verified batches later, on top of the proven contract, rather than importing a second orchestrator now.

Ringer remains useful in three roles: a product reference, a source of test cases and failure modes, and—only if the user separately installs and runs it—a private experiment whose outputs Baton may inspect manually. It is not part of Baton's public runtime architecture in this proposal.

---

## 1. Facts established from the current Ringer source

These are source observations, not Baton recommendations.

| Ringer behavior | Current implementation consequence |
|---|---|
| Flat JSON manifest of tasks | Tasks in one run are independent; there is no dependency graph inside a Ringer manifest |
| Per-task `spec`, `check`, `expect_files`, `verified`, `engine`, `model`, `task_type`, and timeout | The manifest is both the labor brief and the verification/routing envelope |
| `check` runs as a shell command | Exit zero plus non-empty expected files is the pass oracle; arbitrary shell execution is part of the trust model |
| Verification runs after every worker attempt | Verification, rather than worker prose, determines task success |
| Exactly two attempts | A failure or timeout gets one retry with worker-log and check-output context |
| Check success can outweigh a non-zero worker exit | Correct artifacts may pass even if the worker process ended noisily; spawn errors and timeouts remain failures |
| Optional per-task git worktrees | Parallel repo edits are isolated, but passing worktrees are removed after deliverables/reports are harvested |
| Local state, JSONL eval log, SQLite read model, and Ringside | Ringer owns a complete second run store, evidence model, and dashboard |
| First-try pass rate by model and free-form `task_type` | Ringer uses personal verified history as a routing signal; its current promotion floor is deliberately lightweight |
| Engine blocks in TOML | Codex, Grok, and OpenCode/OpenRouter are process adapters independent of Ringer's task model |
| Python 3.11+, macOS/Linux, Windows through WSL | Native Windows is not a stated supported runtime |
| PolyForm Shield 1.0.0 | The license permits broad use but excludes providing a competing product, defined across interfaces and platforms |

Important implementation details that must temper the marketing shorthand:

- A check is **evidence**, not automatically truth. A weak check can pass bad work.
- A worker can sometimes modify the code or tests its check invokes. Without oracle-integrity controls, executable verification can be self-graded.
- First-try pass rate conflates model quality, prompt quality, task difficulty, harness behavior, check strength, and environment health.
- Ringer's worktree lifecycle is optimized for harvested deliverables and exported patches, not Baton's durable branch-for-human-merge contract.
- Ringer's `models` tiers are useful operational heuristics, not statistically strong conclusions at small sample counts.

---

## 2. Baton and Ringer solve different layers

### Baton already owns

- project, job, and run lifecycle under `$BATON_HOME`;
- capability and cost-aware fleet selection;
- usage exhaustion, saturation, prime-hours, and budget policy;
- Research Gate, Plan Gate, and Acceptance Gate;
- a dependency-aware Conductor plan;
- agentic execution in a persistent run worktree and branch;
- proof-by-diff, task diffs, run events, reports, and effective cost;
- dashboard, knowledge, prompt evolution, and human merge policy.

### Ringer demonstrates more convincingly

- an executable contract attached to every labor task;
- linting of obviously weak verification;
- one retry informed by raw failure output;
- first-attempt versus rescued-pass telemetry;
- highly visible parallel batches of independent, checkable work;
- reusable task/check patterns.

### The actual fit

Ringer is not a missing Baton worker and not a missing Baton conductor. It is evidence that **Baton's labor task needs a verification sub-lifecycle**:

```text
research -> plan -> Plan Gate -> labor -> task verification -> optional retry
                                      \-> next DAG task only after verified pass

successful DAG -> Acceptance Gate -> human branch review/merge
```

The check answers, "Did this task satisfy its objective contract?" The Acceptance Gate answers, "Is the combined result good enough to ship?" Neither replaces the other.

---

## 3. Approaches considered

### Approach A — Baton-native verification contract (recommended)

Add verification, retry, and attempt evidence to Baton's existing Conductor and agentic executor. Reuse the existing fleet, run directory, worktree branch, event stream, dashboard, capability vocabulary, and gates.

**Advantages**

- one source of truth for providers, cost, usage, runs, and routing;
- native Windows compatibility remains attainable;
- no runtime or license dependency on a competing orchestrator;
- exact fit with Baton's persistent branch and DAG semantics;
- verification evidence can be provenance- and integrity-aware;
- smallest coherent improvement to the shipped product.

**Costs**

- Baton must implement and test a verification runner and retry policy;
- it does not instantly reproduce Ringside or Ringer's template library;
- parallel independent batches remain a later Baton design problem.

### Approach B — private, user-installed Ringer bridge (conditional experiment)

A local script outside Baton's distributable plugin may invoke a user-installed Ringer and leave both products' configuration, state, and licensing separate. Baton may link to a result path or manually summarize exported JSON.

**Advantages**

- fastest way to try Ringer's complete experience;
- keeps Ringside and upstream updates intact;
- useful for deciding which task shapes deserve native Baton support.

**Costs and limits**

- WSL/native-Windows path and process boundaries on this machine;
- duplicated fleet configuration, credentials, dashboards, logs, and routing policy;
- no stable public integration contract is promised by upstream;
- Baton budgets cannot reliably govern nested worker spend;
- legal permission for productized coupling remains unresolved.

This is a lab experiment, not the public product architecture.

### Approach C — ship Ringer as a Baton labor backend (rejected unless licensed)

This would add `/baton:ringer`, a Ringer entry in a registry, or a Conductor spawner that translates plans into Ringer manifests.

It is rejected as the default because it duplicates core Baton responsibilities, creates two control planes, exposes model-authored shell checks, weakens cost governance, clashes with Baton's worktree lifecycle, and may constitute use in a competing product under PolyForm Shield. Explicit commercial/redistribution permission could change the licensing conclusion, but not the technical duplication.

---

## 4. Recommended architecture

```text
                         BATON OWNS
  goal -> planner -> Plan Gate -> ordered task DAG
                                  |
                                  v
                    Agentic worker in run worktree
                                  |
                                  v
                  Baton Verification Contract Runner
                    | pass                 | fail
                    v                      v
              next DAG task       retry once with evidence
                                           |
                                           v
                                     pass or stop
                                  |
                                  v
                  cumulative diff + Acceptance Gate
                                  |
                                  v
                   preserved branch for human merge
```

No new provider type, engine config, state root, or dashboard is required for the first three slices.

### Ownership boundaries

| Component | Owns |
|---|---|
| Planner / Plan Gate | task scope, ordering, capability, cost tier, reversibility, and whether a verification contract is meaningful |
| Fleet router | worker selection under cost, quality, usage, and saturation policy |
| Agentic executor | isolated edits, worker process result, task diff, and preserved branch |
| Verification runner | trusted command execution, expected artifacts, path/integrity checks, timeout, and raw evidence |
| Retry policy | at most one evidence-informed redispatch to the same logical task |
| Acceptance Gate | combined product quality after all mechanically verified tasks |
| Human | merge, publish, destructive actions, credentials, and any unsafe verification authorization |

---

## 5. Baton task verification contract

The Conductor's normalized task object gains an optional `verify_profile` name. It stays optional during migration so existing plans remain valid. The planner may select a profile but may not invent executable commands.

```json
{
  "id": "t2",
  "desc": "Add invoice total validation and focused tests",
  "command": "",
  "capability": "code-gen",
  "model_pick": "",
  "depends_on": ["t1"],
  "est_cost_tier": "free",
  "reversible": true,
  "allowed_paths": [
    "src/invoice.py",
    "tests/test_invoice.py"
  ],
  "verify_profile": "invoice-focused"
}
```

Profiles live in a project-owned `.baton/verification.json` committed before the run:

```json
{
  "schema": 1,
  "profiles": {
    "invoice-focused": {
      "argv": [
        "python",
        "-m",
        "pytest",
        "tests/test_invoice.py",
        "-q"
      ],
      "cwd": ".",
      "timeout_s": 300,
      "expect_files": [],
      "protected_paths": [
        "tests/fixtures/invoice_cases.json"
      ],
      "proves": "the focused invoice validation suite passes against the protected fixture cases"
    }
  }
}
```

Before labor starts, Baton resolves the named profile from the run's base commit, validates it, and copies the immutable resolved contract to the Baton run directory. The worker cannot edit that copy. A later worktree change to `.baton/verification.json` cannot change the current run's oracle.

An explicit user-authored batch file may carry an inline contract only after Baton displays the exact command and the user authorizes it. `/baton:go -Execute` planner output never receives that privilege.

### Required semantics

- `verify_profile` must exist in the base revision's project configuration; an unknown profile makes the plan invalid before labor.
- `argv` is a non-empty array of strings executed without a shell.
- `cwd` is relative to the run worktree and cannot escape it.
- `timeout_s` is positive and capped by policy.
- `expect_files` contains worktree-relative files that must exist and be non-empty after the command.
- `protected_paths` names oracle inputs that must match their pre-task content hash.
- `proves` is a required plain-language statement owned by the trusted profile and shown in reports and the dashboard.
- `allowed_paths` belongs to the Baton task, not the verifier; it constrains task diff scope.
- The verifier captures combined stdout/stderr verbatim up to a documented byte cap.
- Success requires exit zero, all expected files present, allowed-path compliance, and protected-path integrity.

### Why `argv`, not a Ringer-style shell string

Ringer assumes a trusted manifest author and intentionally accepts arbitrary shell commands. Baton can ask a model to create a plan and then run it full-auto. Automatically executing planner-authored commands—even as an argument vector—would add destructive-action paths that Baton's `reversible` flag cannot reliably classify. `argv` solves shell interpolation; trusted profiles solve command provenance.

An argument vector removes shell interpolation, pipes, redirection, command substitution, and quoting ambiguity. Complex verification should live in a checked-in script invoked as an argument vector, for example:

```json
{"argv":["pwsh","-NoProfile","-File","scripts/test-invoice.ps1"]}
```

Profiles containing `pwsh -Command`, `cmd /c`, `sh -c`, language-eval flags such as `python -c`, and equivalent command-construction escapes fail lint. The initial implementation has no unsafe bypass; add one only after a separate threat-model decision.

---

## 6. Oracle integrity: the requirement Ringer's slogan omits

"Execute the artifact" is better than trusting an agent summary, but it is not sufficient if the worker controls the oracle.

Examples of false confidence:

- the worker edits an existing test so it no longer asserts the required behavior;
- the worker replaces a check helper with a script that exits zero;
- the check only verifies file existence while the file contents are wrong;
- the worker writes the expected success marker without performing the operation;
- the task changes files outside its assigned scope and the focused check still passes.

Baton should grade verification evidence by integrity:

| Evidence grade | Conditions | Learning use |
|---|---|---|
| `strong` | command exits zero; at least one protected oracle input is unchanged; a non-empty allowed-path set contains the entire diff; contract lint clean | may contribute an executable-verification signal to capability learning |
| `bounded` | command exits zero and scope is clean, but the task legitimately authored or modified part of the test surface | record in reports; low-weight routing evidence only |
| `weak` | only expected-file or marker checks; no protected oracle; broad mutable test surface | operational evidence only; do not train routing automatically |
| `invalid` | path escape, protected-path mutation, timeout, missing file, disallowed shell, or command failure | task failure |

The grade must be computed deterministically from the contract and diff. A worker cannot select its own grade.

---

## 7. Execution and retry semantics

### Per attempt

1. Resolve and freeze the named verification profile from the base revision, then snapshot the worktree tree hash and hashes of `protected_paths`.
2. Dispatch the selected agentic worker using the existing prompt transport and worktree.
3. Capture the worker exit, raw log path, duration, and any token/metering data.
4. Compute the task diff and enforce `allowed_paths` when specified.
5. Run the verification `argv` with closed stdin, combined output, a new process group, and the contract timeout.
6. Check expected files and protected-path hashes.
7. Write a complete attempt row before deciding whether to continue.

### Outcome precedence

- Spawn failure or verification infrastructure failure: task fails; do not pretend it was a model-quality failure.
- Verification pass: task passes even if the worker process returned non-zero, but the non-zero exit is retained as a warning in evidence.
- Verification fail or worker timeout: eligible for one retry.
- Scope violation or protected-oracle mutation: task fails closed and is not auto-retried; retrying the same untrusted behavior is unsafe.
- No verification contract: retain legacy behavior during migration and mark the task `unverified` in evidence.

### One retry, exactly

The retry prompt contains:

- the original task description, unchanged;
- the deterministic verification failure category;
- a bounded raw output excerpt;
- missing expected files;
- the task's current diff summary;
- an instruction to fix the existing work, not restart or broaden scope.

The second attempt runs in the same run worktree so it can repair partial work. There is no third attempt. A second failure stops the Conductor with the task id and full evidence paths.

Retries caused by infrastructure failure, usage exhaustion, or missing executables must not count as model-quality failures.

---

## 8. Planning and gate interaction

### Plan Gate

Plan Gate remains responsible for whether the proposed task and verification are sensible. Its finding vocabulary may eventually add `verification`, but that should be a Plan Gate revision after the base d080 implementation ships—not an unplanned expansion of d080 now.

Review questions for a task contract:

- Does the check exercise the requested behavior rather than a proxy?
- Can the worker modify or spoof the oracle?
- Are the allowed paths narrow enough?
- Does the command exist on the target platform?
- Is the timeout proportionate?
- Is the contract stronger than proof-by-diff alone?

### Acceptance Gate

The final Acceptance Gate remains distinct and uses the cumulative diff or produced artifact. A mechanically verified task can still produce poor architecture, insecure behavior, misleading copy, or ugly UX.

### Human merge gate

Baton preserves the `baton/run-<id>` branch and worktree. Verified success never auto-merges. This is intentionally different from Ringer's passing-worktree cleanup.

---

## 9. Parallelism: defer the executor expansion

Ringer's strongest demo is parallel fan-out, but Baton's first missing primitive is trustworthy per-task verification, not another fan-out mechanism.

Do not make the current one-worktree-per-run Conductor execute multiple editing workers concurrently in that worktree. It would reintroduce collisions that the worktree exists to prevent.

After verification is proven, a separate design may support two batch modes:

1. **Artifact batch:** independent tasks write only to separate Baton run directories. Safe to run concurrently with a semaphore.
2. **Repository batch:** each ready task gets its own child worktree/branch, verified independently, and produces a durable patch/branch for Baton's existing merge workflow. No passing worktree is deleted before its patch and evidence are durable.

Dependency-aware ready sets can be derived from Baton's existing DAG. A flat Ringer-style nested task list inside one Conductor node is unnecessary and would hide task-level cost, routing, events, and dependencies from Baton.

---

## 10. Evidence model and run artifacts

For each verified task, Baton writes:

```text
$BATON_HOME/runs/<run-id>/
  plan.json
  events.jsonl
  decisions.jsonl
  changes.diff
  tasks/
    <task-id>.diff
    <task-id>/
      contract.json
      attempts.jsonl
      verification.json
      check-output.txt
```

### `attempts.jsonl` minimum fields

| Field | Meaning |
|---|---|
| `run_id`, `task_id`, `attempt` | stable lineage |
| `capability`, `worker`, `cost_tier` | Baton's native routing identity |
| `worker_exit`, `worker_timeout`, `worker_tokens` | process evidence |
| `verification_exit`, `verification_timeout` | check evidence |
| `verification_grade` | strong/bounded/weak/invalid |
| `verdict` | pass/fail/infrastructure-error/scope-violation |
| `first_try` | true only for attempt one |
| `duration_ms` | attempt wall time |
| `output_path`, `diff_path` | evidence pointers, not large embedded blobs |
| `failure_category` | stable taxonomy for retry and analysis |

### Event kinds

- `task-verification-started`
- `task-verification-passed`
- `task-verification-failed`
- `task-retry-started`
- `task-scope-violation`
- `task-unverified`

Existing dashboard readers already consume `events.jsonl`; the first UI slice should render these events without creating another run store or embedding Ringside.

---

## 11. Learning and economics

Ringer's `task_type` should not be imported as a second taxonomy. Baton already has `capability`, provider identity, routing journals, quality weights, usage state, and effective-cost records.

### Correct signal placement

- Task verification contributes to **capability × worker quality evidence**.
- Final Acceptance Gate contributes to **run-level realized quality and effective cost**.
- Usage exhaustion and infrastructure errors contribute to availability diagnostics, not quality penalties.
- Retry count contributes to attempt cost and first-try performance.

Do not write a Ringer task pass directly into Baton's `effective-cost.json`. Baton's effective cost is a run-level ratio tied to the final acceptance verdict and worker cost shares. Mixing task checks into that record would change the metric's meaning.

### Proposed routing weight

Add an executable-verification signal only after enough data exists and only for `strong` evidence. Its weight should sit below explicit human feedback and above the current free heuristic signal. A reasonable design candidate is:

```text
human rating > strong executable verification > LLM judge > heuristic process pass
```

Exact weights and sample floors require a separate decision. The first slice records data without changing routing.

### First-try reporting

Report, by capability and worker:

- verified tasks;
- first-try verified-pass rate;
- rescued-pass rate after one retry;
- infrastructure-error rate;
- median attempt duration;
- confidence/sample count;
- evidence-grade mix.

Never call a worker "proven" from three heterogeneous tasks without showing the sample count and evidence grade.

---

## 12. Safety and trust boundaries

1. Verification commands are code execution and require the same seriousness as labor commands.
2. Planner output may use only argument vectors; shell escapes are rejected.
3. Verification runs inside the isolated worktree with closed stdin and a bounded environment.
4. `cwd`, expected files, protected paths, and evidence paths must resolve inside their declared roots.
5. The worker must not receive write access to the Baton run directory containing its contract and evidence.
6. Contract and protected-path hashes are captured before labor.
7. Raw worker/check output is stored locally and treated as untrusted content when displayed.
8. Secrets are never injected into verification prompts or output; credentialed/live checks require explicit user authorization.
9. Networked, destructive, publish, install, login, and external-write checks are outside the automatic contract and require an existing Baton interrupt/human gate.
10. Missing verification infrastructure fails the task closed. Fail-open is suitable for advisory reviewers, not for the labor oracle a task explicitly requires.

---

## 13. Windows and cross-platform stance

The recommended native design must work in Baton's existing PowerShell/Windows environment.

- Use `System.Diagnostics.Process` or an equivalent argument-list API, not a shell command string.
- Use process-tree termination that is tested on Windows and remains compatible with PowerShell 7.
- Normalize paths through resolved filesystem APIs; do not translate through WSL in the public path.
- Keep commands platform-explicit in the contract. `python` versus `python3`, `/bin/sh`, and POSIX test syntax cannot be assumed.
- Preserve the 965-byte shell-argument rule by keeping labor prompts on Baton's stdin-safe provider path and verification arguments small.

A private Ringer experiment may use WSL, but that should not define Baton's public state layout, path contracts, or support burden.

---

## 14. Licensing boundary

Ringer's PolyForm Shield license contains a broad noncompete condition covering products that compete through different interfaces and platforms. Baton is already an AI-development orchestration product with overlapping labor, model-routing, evaluation, and dashboard features.

Therefore:

- do not vendor or fork Ringer code;
- do not copy templates, dashboard assets, helper scripts, skill/hooks, or implementation text into Baton;
- do not distribute a Ringer binary or clone as part of bootstrap;
- do not market Baton as including Ringer compatibility without legal/licensor clearance;
- treat a public adapter as blocked pending explicit permission;
- retain citations to Ringer as prior art/product research;
- obtain qualified legal advice for any commercial or distributed coupling.

This document is an engineering risk assessment, not legal advice.

---

## 15. Proposed implementation slices

Each slice requires its own approved design/plan before code.

### V0 — Product and license decision

Record the binding choice in Grimdex: Baton implements a native verification contract; Ringer remains an external research reference unless licensed otherwise.

**Done when:** the decision names the public/private boundary and rejects accidental dependency or code copying.

### V1 — Pure verification contract and runner

**Proposed files**

- Create `scripts/verification-lib.ps1`
- Create `scripts/test-verification-lib.ps1`
- Modify `scripts/bootstrap.ps1`

**Responsibilities**

- normalize and lint the contract;
- enforce path roots and protected hashes;
- invoke argument-vector checks with timeout and closed stdin;
- evaluate expected files and diff scope;
- return a pure result object and write no global routing data.

**Done when:** hermetic tests cover pass, command failure, timeout, missing artifact, path escape, protected-path mutation, scope violation, output truncation, and platform-safe argv construction.

### V2 — Conductor/executor integration and one retry

**Proposed files**

- Modify `scripts/conductor-lib.ps1`
- Modify `scripts/fleet-executor-lib.ps1`
- Modify `scripts/fleet-go.ps1`
- Modify `prompts/conductor-planner.txt`
- Modify `scripts/test-conductor-lib.ps1`
- Modify `scripts/test-fleet-executor-lib.ps1`

**Responsibilities**

- preserve optional `verify_profile` and `allowed_paths` fields during plan normalization;
- preflight contracts before labor;
- run verification after each agentic attempt;
- retry once with bounded evidence;
- stop on second failure or integrity violation;
- keep legacy tasks behavior-compatible but visibly unverified.

**Done when:** a scratch repo live smoke produces a first-attempt failure, an evidence-informed repair, a verified pass, durable task evidence, and a preserved run branch.

### V3 — Reports, dashboard, and evidence collection

**Proposed files**

- Modify `scripts/conductor-lib.ps1` report formatting
- Modify `dashboard/models/runs.py`
- Modify `dashboard/readers/runs.py` only if event rendering needs structured fields
- Modify relevant dashboard templates
- Add dashboard/reader tests

**Responsibilities**

- render contract, proof sentence, attempts, verification grade, and evidence links;
- distinguish unverified, verified, retried, failed, and infrastructure-error tasks;
- avoid large output blobs in `events.jsonl`.

### V4 — Routing evidence, initially observe-only

**Proposed files**

- Extend `scripts/routing-learn.ps1` with a reader for verified-attempt evidence
- Extend `/baton:effective-cost` or add a verification subsection without changing the effective-cost formula
- Add hermetic aggregation tests

**Responsibilities**

- show first-try and rescued pass rates by Baton capability/worker;
- exclude weak evidence and infrastructure failures from quality scoring;
- keep routing changes disabled until sample floors and weights are separately approved.

### V5 — Parallel verified batches

Separate design. Reuse the verified-task contract and choose explicit artifact-batch versus repo-batch isolation. Do not nest an opaque second task system inside a Conductor node.

### V6 — Optional private Ringer experiment

Only after V0 and only outside the distributable plugin unless licensed. The experiment should compare operator experience and task outcomes; it should not write Baton's routing or effective-cost data automatically.

---

## 16. Test matrix

| Scenario | Required result |
|---|---|
| Worker exit 0, verification exit 0 | verified pass |
| Worker exit non-zero, verification exit 0 | verified pass with worker warning |
| Worker exit 0, verification exit non-zero | retry once, then pass/fail |
| Worker timeout | one retry, then failure; timeout recorded |
| Verification timeout | retry once unless policy marks infrastructure failure |
| Expected file absent or empty | verification fail with named file |
| Diff outside `allowed_paths` | fail closed, no retry |
| Protected oracle changed | fail closed, no retry |
| Check script newly authored by worker | evidence cannot be `strong` |
| Planner names an unknown verification profile | plan rejected before labor |
| Profile changed only inside the run worktree | frozen base-revision contract remains authoritative |
| Profile contains `sh -c`, `pwsh -Command`, `cmd /c`, or language eval | profile rejected before labor |
| Relative path escapes with `..` or symlink | contract rejected/fails closed |
| No verification contract | legacy execution plus `unverified` evidence |
| Second attempt passes | task marked rescued; first-try=false |
| Second attempt fails | run stops at task with evidence pointers |
| Acceptance Gate rejects verified diff | final run remains rejected |
| Missing verifier executable | infrastructure failure, not model-quality penalty |

Required regression gate when implementation eventually exists:

```text
python -m pytest kb dashboard -q
pwsh -NoProfile -File scripts/test-verification-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
all other scripts/test-*.ps1 suites required by the Baton merge gate
```

Live model and Ringer runs remain opt-in acceptance tests, never unit-test dependencies.

---

## 17. Success criteria

The native Ringer-inspired layer is successful when:

1. A Conductor task can select a bounded, platform-correct verification profile frozen from the base revision.
2. The worker cannot pass by saying "done," merely changing a diff, or weakening a protected oracle.
3. A failed verification gets exactly one useful retry with raw evidence.
4. The preserved Baton branch contains the work; task evidence survives independently under `$BATON_HOME`.
5. The dashboard shows what was proved, how many attempts it took, and where the raw evidence lives.
6. Baton's router can later learn from strong task evidence without corrupting the run-level effective-cost metric.
7. Research, Plan, Acceptance, and human merge gates retain their existing responsibilities.
8. The public plugin has no Ringer runtime, source, template, hook, asset, config, or state dependency.
9. Native Windows remains a first-class Baton target.
10. Any private Ringer experiment is clearly labeled external, optional, separately installed, and non-authoritative.

---

## 18. Final recommendation

Do not make Baton "support Ringer" first. Make Baton learn the lesson Ringer proves:

> Labor is complete only when an independent contract produces durable evidence, and the system remembers whether that happened on the first try.

Ship that as a small native vertical slice before pursuing parallel batches. It closes Baton's most important labor-trust gap without importing a second conductor, a second dashboard, a second router, or a licensing problem.
