# Go Execute Stakes Depth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace PR-A's missing-stakes shim with validated planner stakes, deterministic per-task depth routing, and auditable run decisions for issue #98.

**Architecture:** Conductor owns plan normalization, override precedence, validation, and the additive decision/report contract. `fleet-executor-lib.ps1` owns the pure stakes-to-routing policy and applies it before worker selection; its verifying wrapper preserves the final attempt's policy metadata. `fleet-go.ps1` exposes the operator override and passes it to both boundaries.

**Tech Stack:** PowerShell 7, Baton's hand-rolled YAML fleet registry, JSONL run artifacts, hermetic PowerShell test scripts.

## Global Constraints

- The locked addendum in `docs/superpowers/specs/2026-07-14-go-execute-defaults-flip-design.md` overrides the design body.
- Write text files as `utf8NoBOM`; never use forbidden PowerShell variable names.
- Keep all test state under `$env:TEMP` and restore environment changes in `try/finally`.
- Keep non-execute behavior unchanged except the explicitly additive planner schema/default fields.
- Preserve the human merge boundary and PR-A's shipped gate/exit semantics.

---

### Task 1: Planner schema, override plumbing, and dead parameter cleanup

**Files:**
- Modify: `prompts/conductor-planner.txt`
- Modify: `scripts/conductor-lib.ps1`
- Modify: `scripts/fleet-go.ps1`
- Modify: `commands/go.md`
- Test: `scripts/test-conductor-lib.ps1`
- Test: `scripts/test-fleet-go-execute.ps1`

**Interfaces:**
- Produces normalized task fields `stakes` and `stakes_basis`.
- Produces CLI `-Stakes` with alias `-StakesOverride`, passed internally as `StakesOverride`.
- Removes dead `Invoke-Conductor -RequireVerify`; fleet-go's installed `VerifyPreflight` remains the enforcement contract.

- [ ] Add failing parser/prompt/execute tests for valid stakes preservation, missing-field defaults, invalid values/bases, and operator override precedence.
- [ ] Run `pwsh -NoProfile -File scripts/test-conductor-lib.ps1` and `pwsh -NoProfile -File scripts/test-fleet-go-execute.ps1`; confirm the new assertions fail because stakes are not yet schema fields or CLI parameters.
- [ ] Add `stakes`/`stakes_basis` to the planner schema and guidance; normalize missing fields to `standard` / `legacy plan omitted stakes`; reject supplied invalid stakes or empty supplied bases.
- [ ] Add `[Alias('StakesOverride')][ValidateSet('low','standard','high')][string]$Stakes` to fleet-go, apply override basis `operator override: --stakes <value>`, replace the #98 warning with the applied standard-policy warning, and remove `RequireVerify` from the Conductor splat/API.
- [ ] Re-run both suites and confirm all assertions pass.
- [ ] Commit the schema/CLI/normalization unit.

### Task 2: Pure depth mapping and execute spawner routing

**Files:**
- Modify: `scripts/fleet-executor-lib.ps1`
- Modify: `scripts/fleet-go.ps1`
- Test: `scripts/test-fleet-executor-lib.ps1`

**Interfaces:**
- Produces `Resolve-TaskDepthPolicy -Task <object> -RunMaxCostTier local|free|paid [-StakesOverride low|standard|high]`.
- Returns `stakes`, `stakes_basis`, `depth_tier`, `selection_mode`, and `max_cost_tier`.
- Extends spawner results with `depth_applied`, `tier_cap`, and `selected_cost_tier` plus the resolved policy fields.

- [ ] Add a failing table test for low/standard/high across run and task caps, plus override precedence.
- [ ] Add failing spawner tests proving `SelectionMode`, effective cap, generic tier dispatch, and `depth_applied=false` for providers without a named tier.
- [ ] Run `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1`; confirm failures are specifically the missing resolver/metadata behavior.
- [ ] Implement the pure rank/minimum mapping: low=`low/economy/min(run,free,estimate)`, standard=`med/economy/min(run,estimate)`, high=`high/champion/run`.
- [ ] Resolve policy before `Select-Capability`, pass `-Tier` to real fleet dispatch, expose the requested tier to the dispatcher seam, and record whether the selected provider actually defines `tier_<depth>`.
- [ ] Re-run the executor suite and confirm it passes.
- [ ] Commit the policy/routing unit.

### Task 3: Additive decisions journal and report visibility

**Files:**
- Modify: `scripts/conductor-lib.ps1`
- Modify: `scripts/fleet-executor-lib.ps1`
- Test: `scripts/test-conductor-lib.ps1`
- Test: `scripts/test-fleet-executor-lib.ps1`

**Interfaces:**
- Extends `New-RunDecision` with optional `stakes`, `stakes_basis`, `depth_tier`, `depth_applied`, `selection_mode`, `tier_cap`, and `selected_cost_tier` while retaining `cost_tier`.
- Verifying results preserve the final inner attempt's policy fields.

- [ ] Add failing tests for exact JSONL fields, compact report text, legacy `cost_tier`, and verifier retry preservation.
- [ ] Run both focused suites and confirm the new assertions fail on absent metadata.
- [ ] Copy policy fields from spawner result into `New-RunDecision`, serialize them additively, and render stakes/depth/mode/cap/actual tier in each `## Decisions` line.
- [ ] Copy the final inner result's policy fields through `New-VerifyingSpawner`.
- [ ] Re-run both focused suites and confirm they pass.
- [ ] Commit the audit/logging unit.

### Task 4: Regression verification and branch handoff

**Files:**
- Verify all modified files and fixtures.

- [ ] Run every `scripts/test-*.ps1` suite and capture per-suite assertion/pass counts.
- [ ] Run `python -m pytest kb dashboard -q` and capture its exact pass/fail count.
- [ ] Run `git diff --check`, scan modified PowerShell for forbidden variable names, and verify changed text files have no UTF-8 BOM.
- [ ] Review the final diff against PR-B scope items 1–6 and the locked addendum.
- [ ] Commit any verification-driven fixes, then report commit SHAs and exact results without merging or deleting the branch.
