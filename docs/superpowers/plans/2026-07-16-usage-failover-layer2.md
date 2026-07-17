# Usage-Aware Failover Layer 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fail-open, TTL-cached Codex app-server usage probe and enforce box-private pre-flight buffer policy at Baton's agentic dispatch seam without weakening slice 1's quality, stakes/depth, cost, or one-hop safeguards.

**Architecture:** `usage-probe-lib.ps1` owns the Codex JSON-RPC transport, normalized observations, append-only raw cache, pure advisory math, and structured pre-flight rows. `Read-Fleet` parses and validates an optional nested `usage_policy`; `New-AgenticSpawner` probes/ranks/holds at the point where it already has the capability ladder, quality floor, task policy, and cost ceiling. Proactive `limited` rows are TTL-expiring advisory state; missing, stale, malformed, timed-out, or unavailable probes fail open and never block dispatch.

**Tech Stack:** PowerShell 7, Codex app-server JSON-RPC over stdio, append-only JSONL, Baton's existing hand-rolled fleet YAML parser and Usage Governor, hermetic PowerShell script tests.

## Global Constraints

- Authoritative scope is d090 plus issue #94's comment titled `Layer 2 scope locked (d090)`; the design spec sections 3.1, 3.3, 4, and 6 supply the observation, TTL, fail-open, hysteresis, and adjacent-track rules.
- Build Codex app-server adapter #1 only. Do not scrape Grok/Gemini TUIs, implement Claude status-line ingestion, or call Copilot billing during dispatch.
- `usage_policy` absent means no pre-flight and preserves existing behavior. Inside a present block, defaults are `soft_cap_5h = 75`, `soft_cap_weekly = 85`, `probe = false`; invalid booleans, percentages, or allowances fail config parsing with the provider name.
- Real quotas, plan names, reset values, and allowances are box-private. Shared seed/docs/tests use comments, policy defaults, and obvious placeholders only.
- Probe timeout is approximately 20 seconds. Any transport, protocol, parse, process, binary, or cache failure returns `$null` or ignores stale data and dispatches normally.
- Cache TTL defaults to 600 seconds. A successful response is always appended raw to the box-private probe cache; stale cache data never hard-excludes a provider.
- Epoch `resetsAt` values are seconds and must be converted with `[DateTimeOffset]::FromUnixTimeSeconds()` to ISO-8601 with offset.
- Over-cap probe observations append advisory `limited` rows only; under-cap observations are cached but do not alter Usage Governor state.
- Pre-flight policy permits at most one provider hop. A pre-flight reroute consumes the task's failover hop; a later reactive failure does not cascade to a third provider.
- Reroutes reuse slice 1's `quality_first` peer filter, re-resolve task stakes/depth, retain the run's `max_cost_tier`, and never cross a quality or cost floor.
- Median-token fit, monthly pace, and surplus-spend are observe-first. Token-fit and monthly pace never auto-hold in this PR. Surplus is a small ranking preference only for fresh, adapter-backed subscription CLI observations inside the reset guard.
- PowerShell 7; utf8NoBOM; 965-byte shell-argument ceiling; never use automatic-variable names `$args`, `$input`, `$event`, `$matches`, `$host`, or `$pid`; guard every divide; use `ConvertTo-Json -InputObject @(...)` for arrays; unary comma only on direct-assignment returns.
- Tests isolate `BATON_HOME`, journals, caches, fleets, and worktrees under a unique temp root. They never read/write real `~/.baton` or `~/.claude`, call a vendor API, or spawn the real `codex` executable.
- Do not bump a version, open a PR, merge, or modify Grimdex unless a genuinely new decision is made.

---

## Spec-to-master reconciliation

1. **The generic `Invoke-Fleet` call is too late and too context-poor for policy.** It knows a provider name but not the full peer ladder, learned-quality floor, task stakes/depth, or effective cost ceiling. The proactive gate therefore belongs before `Invoke-AgenticDispatchAttempt` inside `New-AgenticSpawner`; generic dispatch keeps slice 1's reactive observation behavior.
2. **Fresh proactive `limited` state must expire by TTL, not vendor reset.** Existing `Get-WorkerState` keeps a `limited` row active until `reset_at`. Layer 2 rows carry `source = app_server_probe`, `observed_at`, and `ttl`; the fold must treat `observed_at + ttl` as the advisory expiry while retaining vendor `reset_at` for operator copy.
3. **The raw probe cache is separate from the Usage Governor journal.** The cache stores every successful raw app-server response for reuse and diagnostics. The Usage Governor receives only over-threshold `limited` observations and structured `preflight` decisions, avoiding under-cap state noise.
4. **Surplus preference consumes fresh cache, not a new probe of every candidate.** Candidate ranking may use only fresh cached adapter data. The selected provider is then probed if needed before dispatch. This preserves the 10-minute cache rule and prevents candidate enumeration from spawning multiple app servers.
5. **Monthly pace is a generic observe-only consumer in this slice.** It reads the latest `paid_credit`/`billing_api` observation when a `monthly_allowance` is configured; adapter #3 remains out of scope. No observation means no advisory.
6. **Token-fit is explicitly approximate.** `tok:N` has burn units while the probe reports a percentage. The helper reports the median of the provider's last 20 dispatches and estimates a typical percentage share only when a nonzero same-window token sample and nonzero `used_pct` exist. It can emit copy, never route.

### Task 1: Parse and validate the optional usage policy

**Files:**
- Modify: `scripts/fleet-lib.ps1`
- Modify: `scripts/test-fleet-lib.ps1`
- Modify: `references/fleet.yaml`

**Interfaces:**
- Produces: `ConvertTo-FleetUsagePolicy -ProviderName <string> -RawPolicy <hashtable>` returning a normalized hashtable with `probe`, `soft_cap_5h`, `soft_cap_weekly`, and optional `monthly_allowance`.
- `Read-Fleet` stores the normalized object at `provider.usage_policy`; providers without the block have no such key.

- [ ] **Step 1: Write failing parser tests**

Create temp fleets containing: no block; an empty block; explicit valid values; a placeholder-free commented seed; invalid `probe`, percent values below 0/above 100/non-numeric, and a non-positive/non-numeric allowance. Assert absent is untouched, present defaults normalize, and invalid config throws a message naming the provider and field.

Representative assertion:

```powershell
$row = (Read-Fleet -Path $validFleet)[0]
Assert 'usage policy defaults normalize' (
    $row.usage_policy.probe -eq $false -and
    $row.usage_policy.soft_cap_5h -eq 75 -and
    $row.usage_policy.soft_cap_weekly -eq 85)
```

- [ ] **Step 2: Run RED**

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`

Expected: the nested block is not parsed and validation assertions fail.

- [ ] **Step 3: Implement nested parsing and validation**

Generalize the existing `env:` child-block state into named child-block handling for `env` and `usage_policy`. Normalize only when a provider closes so the parser can name it in errors. Keep all existing flat fields and top-level termination behavior unchanged.

- [ ] **Step 4: Add seed comments and run GREEN**

Document a commented `usage_policy` example beside the Codex row with `probe: false`, the two policy defaults, and `monthly_allowance: <enter allowance>`; explain the GitHub avatar -> Copilot Settings -> usage path. Assert no live/uncommented policy and no numeric allowance appear in the seed.

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`

Expected: all checks PASS.

Commit: `feat(fleet): parse usage buffer policy`

### Task 2: Build the Codex app-server adapter and raw TTL cache

**Files:**
- Create: `scripts/usage-probe-lib.ps1`
- Create: `scripts/test-usage-probe.ps1`

**Interfaces:**
- Produces: `Get-BatonPluginVersion` returning the repository/plugin manifest version or a neutral fallback string.
- Produces: `Invoke-CodexRateLimitTransport -ClientVersion <string> -TimeoutSeconds <int>` returning the id-2 JSON-RPC response object or `$null`.
- Produces: `ConvertFrom-CodexRateLimitResponse -Worker <string> -Response <object> -ObservedAt <datetime> -TtlSeconds <int>` returning normalized five-hour/weekly observation rows or `$null` for an invalid response.
- Produces: `Get-CodexUsageProbe -Worker <string> [-Transport <scriptblock>] [-Now <datetime>] [-TimeoutSeconds <int>] [-TtlSeconds <int>]` returning `{ raw, observations }` or `$null`.
- Produces: `Add-UsageProbeCacheRow`, `Get-FreshUsageProbeCache` over append-only `usage-probe-cache.jsonl`.

- [ ] **Step 1: Write adapter fixtures and failing tests**

Inject transport scriptblocks for: valid primary+secondary; primary only; timeout throw; garbage string; missing-binary throw; id/error result; millisecond-looking/out-of-range epoch; and a response with nullable fields. Assert the injected seam is called once and no test resolves or launches `codex`.

Representative transport:

```powershell
$transport = {
    param($clientVersion, $timeoutSeconds)
    [pscustomobject]@{
        jsonrpc = '2.0'; id = 2
        result = [pscustomobject]@{
            rateLimits = [pscustomobject]@{
                primary = [pscustomobject]@{ usedPercent = 42; windowDurationMins = 300; resetsAt = 1780000000 }
                secondary = [pscustomobject]@{ usedPercent = 51; windowDurationMins = 10080; resetsAt = 1780500000 }
            }
        }
    }
}.GetNewClosure()
```

- [ ] **Step 2: Run RED**

Run: `pwsh -NoProfile -File scripts/test-usage-probe.ps1`

Expected: FAIL because the library/functions do not exist.

- [ ] **Step 3: Implement the transport and normalization**

Use `System.Diagnostics.ProcessStartInfo` with redirected stdin/stdout/stderr, no shell, and no window. Send newline-delimited JSON-RPC in the locked order: id 1 `initialize` with Baton client info, wait for id 1 result, send `initialized`, send id 2 `account/rateLimits/read` with `{}`, and wait for id 2. Ignore unrelated notifications; use async line reads bounded by one overall deadline; kill the process tree in `finally`. Catch every error and return `$null`.

Map only duration 300 to `five_hour` and 10080 to `weekly`. Validate percentages in `[0,100]`, convert epoch seconds with `FromUnixTimeSeconds`, set `source = app_server_probe`, `observed_at`, `ttl = 600`, and a high confidence value.

- [ ] **Step 4: Implement cache behavior and run GREEN**

Append every successful raw response with `worker`, `observed_at`, `ttl`, and `raw`. A fresh read returns the latest non-expired valid row; stale/malformed rows return `$null`. A failed re-probe never refreshes stale data.

Run: `pwsh -NoProfile -File scripts/test-usage-probe.ps1`

Expected: all adapter, failure, epoch-seconds, fresh-cache, and stale-cache checks PASS.

Commit: `feat(usage): add Codex app-server probe`

### Task 3: Add advisory policy math and proactive journal semantics

**Files:**
- Modify: `scripts/usage-probe-lib.ps1`
- Modify: `scripts/usage-lib.ps1`
- Modify: `scripts/test-usage-probe.ps1`
- Modify: `scripts/test-usage.ps1`

**Interfaces:**
- Produces: `Get-UsageProbeCapDecision -Provider <hashtable> -Observations <object[]>` returning over-cap windows and policy knob names.
- Produces: `Get-FleetMedianDispatchTokens -Worker <string> -JournalPath <path> [-SampleSize 20]`.
- Produces: `Get-UsageFitAdvisory`, `Get-MonthlyUsagePaceAdvisory`, and `Test-UsageSurplusSpend` as pure, guarded helpers.
- Produces: `Add-UsageProbeLimitedRows` and `Add-UsagePreflightEvent` using the existing Usage Governor JSONL writer.
- `Get-WorkerState` expires proactive `limited` rows at `observed_at + ttl` before considering vendor reset time.

- [ ] **Step 1: Add failing advisory and TTL tests**

Cover five-hour/weekly caps independently; equality is over cap; last-20 median for odd/even samples; zero/empty/malformed token lines; fit advisory copy; monthly allowance with latest billing observation, day-of-cycle expected pace, zero allowance, missing reset, and no observation; weekly reset at 24 hours and just outside; insufficient headroom; HTTP/non-adapter providers; and proactive `limited` expiry after TTL.

- [ ] **Step 2: Run RED**

Run: `pwsh -NoProfile -File scripts/test-usage-probe.ps1`

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`

Expected: the new helper and TTL assertions fail.

- [ ] **Step 3: Implement guarded observe-only math**

Median sorts the last 20 provider `tok:N` values and averages the two center values for an even count. Fit math guards zero token total and zero `used_pct`; monthly pace guards absent/non-positive allowance and non-positive cycle length; surplus requires a fresh weekly observation, reset in `(0,24h]`, `used_pct < soft_cap_weekly - 20`, CLI kind, and the Codex adapter guard.

- [ ] **Step 4: Implement journal semantics and run GREEN**

Append normalized `limited` rows only for over-cap windows. Append one `preflight` row with `outcome = dispatched|rerouted|held`, `used_pct`, `cap`, `window`, and optional `reason = surplus_spend`. Preserve vendor reset in the row and use TTL for freshness/state expiry.

Run both suites above; expected all checks PASS.

Commit: `feat(usage): add preflight advisories and TTL state`

### Task 4: Enforce pre-flight at the agentic dispatch seam

**Files:**
- Modify: `scripts/fleet-executor-lib.ps1`
- Modify: `scripts/test-fleet-executor-lib.ps1`

**Interfaces:**
- `New-AgenticSpawner` gains optional `ProbeTransport`, `ProbeCachePath`, `FleetJournalPath`, and `ProbeClock` seams with box-private defaults.
- Produces: `Sort-UsageSurplusCandidates` applying a bounded score preference from fresh cache without changing eligibility.
- Produces: `Resolve-AgenticSubstituteCandidates` shared by proactive and reactive paths so quality/cost/stakes/depth filters cannot drift.

- [ ] **Step 1: Add failing end-to-end pre-flight tests**

Using a temp fleet/worktree and injected probe transport, assert: under both caps dispatches the selected provider; over five-hour reroutes to an equal-quality peer without calling the capped provider; over weekly reroutes; over cap with no peer returns a loud hold; timeout, garbage, and missing-binary throws dispatch normally; fresh cache prevents a second transport call; stale cache triggers exactly one new call; raw successful responses are cached under and over cap.

Assert the operator line contains provider, `five_hour`/`weekly`, used percent, reset ISO, and `soft_cap_5h`/`soft_cap_weekly`; assert it is one line. Inspect the Usage Governor rows for `preflight` outcomes and over-cap-only `limited` rows.

- [ ] **Step 2: Add failing interaction/guard tests**

Assert pre-flight reroute re-resolves and preserves stakes/depth/cost fields, rejects lower-quality and above-ceiling peers, consumes the one-hop budget (no later reactive cascade), applies a cached surplus preference only within adapter/reset/headroom/CLI guards, and journals `reason = surplus_spend`. Assert fit and monthly pace copy is appended but never changes the selected worker or hold outcome.

- [ ] **Step 3: Run RED**

Run: `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1`

Expected: new checks fail because dispatch currently invokes the selected provider immediately.

- [ ] **Step 4: Refactor the shared substitute resolver**

Extract the existing retry re-resolution/filter into one helper receiving the original candidate, attempted set, task policy args, capability, and all fleet/router paths. Keep its filter: fleet source, agentic, unattempted, quality greater than or equal to the original, and effective cost ceiling from the re-resolved policy.

- [ ] **Step 5: Implement cached surplus and pre-flight flow**

Rank the already-eligible candidate list using fresh cached surplus metadata. For the selected provider with `usage_policy.probe = true`, use fresh cache or call `Get-CodexUsageProbe`; cache valid raw responses; fail open on null/stale failure. Under cap, dispatch and journal `dispatched`. Over cap, write limited rows, resolve exactly one peer, and either journal/return `held` or journal `rerouted` and dispatch the peer. Mark the original attempted and suppress any later reactive second hop after a proactive reroute.

- [ ] **Step 6: Run GREEN and commit**

Run: `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1`

Run adjacent suites: `scripts/test-usage-probe.ps1`, `scripts/test-usage.ps1`, `scripts/test-fleet-lib.ps1`, `scripts/test-routing-lib.ps1`, `scripts/test-fleet-go-execute.ps1`.

Expected: all checks PASS and slice 1 reactive cases remain unchanged.

Commit: `feat(executor): enforce usage preflight buffer`

### Task 5: Deploy and document Layer 2

**Files:**
- Modify: `scripts/bootstrap.ps1`
- Modify: `scripts/test-bootstrap.ps1`
- Modify: `commands/go.md`
- Modify: `references/fleet.yaml` if Task 1's comments need final copy edits

**Interfaces:**
- Bootstrap deploys `usage-probe-lib.ps1` beside `usage-classify-lib.ps1`.
- `/baton:go --execute` documentation explains opt-in probe policy, fail-open cache, over-cap reroute/hold, advisory fit/pace, and surplus preference.

- [ ] **Step 1: Add failing deploy assertion**

Add an assertion that dry-run bootstrap output names `usage-probe-lib.ps1`, then run `pwsh -NoProfile -File scripts/test-bootstrap.ps1` and confirm RED.

- [ ] **Step 2: Register the library and run GREEN**

Add `usage-probe-lib.ps1` immediately after `usage-classify-lib.ps1` in the deploy list. Rerun the bootstrap suite and expect all checks PASS.

- [ ] **Step 3: Update operator documentation**

Document that `usage_policy` is opt-in per provider, absent means unchanged behavior, app-server failures fail open, stale data is ignored, cap crossings reroute/hold before spend, token-fit/monthly pace are advisory, and surplus cannot override eligibility/quality/cost guards. Keep all quota examples as placeholders or policy defaults.

- [ ] **Step 4: Run doc/seed safety checks and commit**

Search changed docs/seed/tests for real allowance, plan, quota, or reset values; verify the seed's policy remains commented and placeholder-only.

Commit: `docs(usage): explain Layer 2 preflight policy`

### Task 6: Full verification, review, commits, and push

**Files:**
- Review all files changed from `master...HEAD`.

- [ ] **Step 1: Run targeted verification and capture exact counts**

Run the changed/adjacent suites individually and record each printed PASS/FAIL total: usage probe, usage, fleet lib, routing lib, executor, go execute, and bootstrap.

- [ ] **Step 2: Run every PowerShell suite**

Enumerate `scripts/test-*.ps1`, run each with `pwsh -NoProfile -File`, preserve each exit code, and aggregate exact printed `PASS`/`FAIL` counts. Do not stop at the first failure; fix regressions and rerun affected suites, then rerun the full set before claiming green.

- [ ] **Step 3: Run the project Python gate**

Run: `python -m pytest kb dashboard -q`

Expected: all tests pass. Record the exact pytest total.

- [ ] **Step 4: Perform final static review**

Run `git diff --check`; inspect `git status --short`; scan changed PowerShell for forbidden automatic-variable names and unsafe encoding; confirm all divide operations are guarded; confirm `FromUnixTimeSeconds` is used; confirm arrays passed to `ConvertTo-Json` use `-InputObject @(...)`; and confirm tests never use ambient Baton/Claude homes or a real `codex` process.

- [ ] **Step 5: Commit any verification fixes incrementally**

Use focused messages describing the actual fixes. Do not squash or amend the plan commit.

- [ ] **Step 6: Push only the requested branch**

Run: `git push -u origin feature/usage-failover-layer2`

Expected: the remote branch advances. Do not open a PR and do not merge.

