# Usage-Aware Failover Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reactive usage-failure classification and exactly one policy-safe, clean-state substitute retry to Baton's agentic dispatch path.

**Architecture:** A focused `usage-classify-lib.ps1` normalizes dispatch failures and appends observations to the existing Usage Governor JSONL. `Invoke-Fleet` classifies every provider result; `New-AgenticSpawner` consumes that result, re-resolves the v1.17.0 stakes/depth policy, asks the existing router for an equal-or-better eligible peer, restores the pre-attempt tree, and retries once. `Select-Capability` remains the only route-around mechanism.

**Tech Stack:** PowerShell 7, append-only JSONL, Git worktree plumbing, hermetic script tests.

## Global Constraints

- Build only approved design sections 3.1-3.2, 3.4-3.5, 4, 5, and 7 "In (slice 1)"; proactive adapters and section 8-U-A are out.
- Preserve v1.17.0 stakes/depth behavior by re-running `Resolve-TaskDepthPolicy` before substitute selection and dispatching the substitute with that policy's `depth_tier`.
- Default `failover_policy` is `quality_first`: only an equal-or-higher learned-quality peer may replace the failed worker.
- Enforce the policy's `max_cost_tier`; never cross the run ceiling or silently move subscription-included work above it.
- At most one substitute attempt; keep an attempted-worker set; auth/config and ambiguous failures do not enter a failover loop.
- Restore the pre-attempt Git tree before a substitute runs; if restoration cannot be proven, fail loudly without retry.
- Use PowerShell 7, utf8NoBOM, file-based long text, the 965-byte shell-argument ceiling, guarded division, safe variable names, and `ConvertTo-Json -InputObject @(...)` for arrays.
- Tests use only `$env:TEMP` roots with `try/finally`; they never touch real Baton, provider, Claude, or Grimdex state.
- Do not bump a version, open a PR, merge, or create another branch.

---

## Spec-vs-master reconciliation (master `d2295e2`, v1.17.0)

1. **Stakes/depth is now authoritative at the retry seam.** The five-day-old spec predates `Resolve-TaskDepthPolicy`. Current `New-AgenticSpawner` resolves `stakes`, `stakes_basis`, `depth_tier`, `selection_mode`, and an effective per-task `max_cost_tier`, passes the depth tier to `Invoke-Fleet`, and returns those fields for `decisions.jsonl`. The retry must repeat that exact resolution; reusing an ungoverned candidate list would bypass the new stakes caps.
2. **`Select-Capability` already routes around Usage Governor state.** It reads `usage-journal.jsonl` and removes fleet workers in `exhausted`, `cooling_down`, or `waiting_for_reset`; `limited` is a soft down-rank unless conserve mode is active. Slice 1 only needs compatible journal events plus explicit `-UsagePath` plumbing for hermetic tests.
3. **The clean-state retry belongs in `New-AgenticSpawner`, not generic `Invoke-Fleet`.** Generic dispatch knows a provider name but not capability, worktree, task stakes, quality floor, or cost ceiling. It can classify and record every result, while the spawner owns policy-safe substitution and tree restoration.
4. **v1.17.0 already has run-decision policy fields.** The failover return must preserve the original `stakes`, `depth_tier`, `selection_mode`, `tier_cap`, `depth_applied`, and `selected_cost_tier` contract. The one-line `why` becomes the operator-visible hop in the run report; the Usage Governor journal carries structured `original_worker`, `substitute`, `reason`, `reset_at`, and `had_partial_diff` fields.
5. **Existing verification retry is a separate wrapper.** Usage failover remains inside the inner agentic spawner and is capped at one hop. Verified Labor may later invoke that spawner again for evidence-informed repair, but no single spawner invocation cascades usage substitutes.
6. **Scope correction from the approved build instruction:** the design's older “plugin minor bump” line is superseded by “bump nothing”; this branch only adds bootstrap deployment wiring/assertion.

### Task 1: Reactive classifier and Usage Governor observations

**Files:**
- Create: `scripts/usage-classify-lib.ps1`
- Create: `scripts/test-usage-classify.ps1`

**Interfaces:**
- Produces: `Get-UsageFailureObservation -ExitCode <int> -Stdout <string> -Stderr <string> [-Now <datetime>]` returning `{ classification, event, hard_failover, scope, used_pct, reset_at, source, observed_at, ttl, confidence, reason }`.
- Produces: `Register-UsageFailure -Worker <string> -ExitCode <int> -Stdout <string> -Stderr <string> [-UsagePath <path>] [-Now <datetime>]` returning that observation after appending any `lockout`/`cooldown` row to the existing JSONL.
- Produces: `Add-UsageFailoverEvent -OriginalWorker <string> -Substitute <string> -Reason <string> -ResetAt <string> -HadPartialDiff <bool> -UsagePath <path>`.

- [ ] **Step 1: Write classifier fixtures first**

Add independent checks for Codex exhaustion, Claude limit, Grok limit, generic 429 burst, server overload, auth/config, and ambiguous output. Assert category, scope, hard-failover flag, event kind, artificial reset parsing, and the normalized observation fields. Register representative results into a temp `usage-journal.jsonl` and assert `source = 'error_classify'`, parsed reset fields, and no lockout for auth/config or ambiguous failures.

- [ ] **Step 2: Run the new suite and verify RED**

Run: `pwsh -NoProfile -File scripts/test-usage-classify.ps1`

Expected: FAIL because `usage-classify-lib.ps1` and its functions do not exist.

- [ ] **Step 3: Implement the minimal classifier**

Use bounded .NET regexes over combined stdout/stderr, ordered from specific to broad: quota exhaustion, auth/config, burst 429, overload, ambiguous. Parse ISO reset timestamps, `Retry-After` seconds, and simple `resets in` durations. Map quota to `lockout`; burst, overload, and ambiguous failed dispatches to short `cooldown`; mark only quota and burst as `hard_failover`; never turn ambiguous into exhaustion.

- [ ] **Step 4: Run GREEN and commit**

Run: `pwsh -NoProfile -File scripts/test-usage-classify.ps1`

Expected: all checks PASS.

Commit: `feat(usage): classify reactive provider limits`

### Task 2: Classify every fleet result and preserve route-around

**Files:**
- Modify: `scripts/fleet-lib.ps1`
- Modify: `scripts/test-fleet-lib.ps1`
- Modify: `scripts/test-routing-lib.ps1`

**Interfaces:**
- `Invoke-Fleet` gains optional `UsagePath` and attaches `usage_observation` plus `usage_recorded` to returned results.
- `Select-Capability` keeps its existing public contract and consumes the newly written journal rows through its existing `UsagePath` parameter.

- [ ] **Step 1: Add failing fleet and router checks**

In temp roots, dispatch a fake failing CLI result and assert a classified journal row is attached/written. Seed a classifier-shaped lockout row for one of two same-capability workers and assert `Select-Capability` excludes it while preserving the surviving peer and cost cap.

- [ ] **Step 2: Run RED**

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`

Expected: new checks FAIL because fleet dispatch does not classify/register results yet.

- [ ] **Step 3: Wire classification once**

Dot-source `usage-classify-lib.ps1` from `fleet-lib.ps1`. After CLI/HTTP result normalization, call `Register-UsageFailure` with the provider name and result streams, attach the returned observation, and mark it recorded. Do not add a second route-around list to `routing-lib.ps1`.

- [ ] **Step 4: Run GREEN and commit**

Run both suites above; expected all checks PASS.

Commit: `feat(fleet): journal classified usage failures`

### Task 3: One clean, quality-first substitute retry

**Files:**
- Modify: `scripts/fleet-executor-lib.ps1`
- Modify: `scripts/test-fleet-executor-lib.ps1`
- Modify: `scripts/test-fleet-go-execute.ps1`

**Interfaces:**
- Produces: `Restore-WorktreeTreeSnapshot -Worktree <path> -TreeSha <sha>` returning `$true` only when tracked, staged, and new untracked changes are restored to the captured tree.
- `New-AgenticSpawner` gains optional `UsagePath` and `FailoverPolicy = 'quality_first'` without changing existing positional parameters.
- The dispatcher result contract may include `usage_observation`/`usage_recorded`; injected test dispatchers may omit them and are classified by the spawner.

- [ ] **Step 1: Add failing executor tests**

Create a temp fleet with placeholder workers `worker-primary`, `worker-peer`, `worker-lower`, and `worker-paid`. Use a dispatcher that makes a partial file then returns a quota fixture for the primary, and succeeds only for the peer. Assert: exactly two calls; the retry gets the same depth tier; policy is re-resolved; the primary is journal-locked before the second selection; the partial file is absent during the peer call; the attempted set prevents a cascade; the peer meets the original quality and cost ceiling; a `failover` row records all required fields; and `why` is one plain-language hop line.

- [ ] **Step 2: Add failing negative-path tests**

Assert no retry for auth/config, ambiguous, no equal-quality peer, a peer above `max_cost_tier`, or failed tree restoration. Assert “no peer available” is visible. Add a high-stakes case proving champion selection, paid/free ceiling, and `high` depth remain intact on the substitute.

- [ ] **Step 3: Run RED**

Run: `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1`

Expected: new failover checks FAIL because the spawner returns after the first nonzero exit.

- [ ] **Step 4: Implement one-hop retry**

After the first dispatch, classify/register only if generic dispatch did not. On `hard_failover`, call `Resolve-TaskDepthPolicy` again with the original task/run override, call `Select-Capability` again with its `selection_mode`, `max_cost_tier`, and `UsagePath`, filter attempted/non-agentic/lower-quality candidates, restore the captured tree, append one structured `failover` row, and dispatch the peer with the retry policy's `depth_tier`. Never inspect a second failure for another hop.

- [ ] **Step 5: Extend go-output coverage and run GREEN**

Exercise the spawner through the existing hermetic go fixture and assert the final report/decision line contains exactly one `usage failover: worker-primary -> worker-peer` hop while retaining stakes/depth/cap fields.

Run: `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1`

Run: `pwsh -NoProfile -File scripts/test-fleet-go-execute.ps1`

Expected: all checks PASS.

Commit: `feat(executor): retry one clean usage substitute`

### Task 4: Bootstrap registration and full verification

**Files:**
- Modify: `scripts/bootstrap.ps1`
- Modify: `scripts/test-bootstrap.ps1`

**Interfaces:**
- Bootstrap deploys `usage-classify-lib.ps1` beside `usage-lib.ps1` and `fleet-lib.ps1`.

- [ ] **Step 1: Add the failing deploy assertion**

Add `Assert "deploys usage-classify-lib script" ($out -match 'usage-classify-lib\.ps1')` beside the existing Usage Governor assertions.

- [ ] **Step 2: Run RED, register the file, and run GREEN**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`

Expected before manifest edit: the new assertion FAILS. Add `'usage-classify-lib.ps1'` to the deploy array immediately after `'usage-lib.ps1'`; rerun and expect all checks PASS.

- [ ] **Step 3: Run targeted regression suites**

Run the five changed/adjacent suites: classifier, fleet-lib, routing-lib, fleet-executor-lib, fleet-go-execute, and bootstrap. Record exact PASS/FAIL counts from each output.

- [ ] **Step 4: Run the repository-wide required verification**

If `scripts/run-all-tests.ps1` exists, run it. Otherwise enumerate every `scripts/test-*.ps1` and run each with `pwsh -NoProfile -File`, capturing each suite's exit code and exact printed PASS/FAIL count. Then run `python -m pytest kb dashboard -q` because the project handoff names it as a merge-gate suite.

- [ ] **Step 5: Review and commit**

Check `git diff --check`, scan changed scripts for forbidden variable names and encoding drift, confirm no real Baton/provider/Grimdex paths or data entered fixtures, and confirm no version files changed.

Commit: `build(usage): deploy reactive classifier`

- [ ] **Step 6: Push only the requested branch**

Run: `git push origin feature/usage-failover-reactive`

Expected: remote branch advances; no PR is created and nothing is merged.
