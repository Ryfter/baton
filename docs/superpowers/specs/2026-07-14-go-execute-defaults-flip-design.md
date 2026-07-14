# `/baton:go --execute` Defaults Flip Design

**Date:** 2026-07-14  
**Status:** proposal only; no implementation authorization implied  
**Decision served:** Grimdex d086, node #1  
**Scope:** make the existing `/baton:go --execute` path authoritative by default; do not create a second ship pipeline

## Executive summary

`--execute` should compute three default-on policies once: Plan Gate on and fail-loud, acceptance through the named panel and fail-loud, and verification on with edit tasks required to carry a verification profile. Explicit `--no-plan-gate`, `--no-gate`, and `--no-verify` switches restore the corresponding legacy behavior. The acceptance review is already fed the execute diff today; this proposal changes its policy and terminal handling rather than adding another gate. A degraded gate remains distinct from a content verdict: the gate returns `degraded`, and the Conductor converts that into a loud non-success run status instead of pretending the artifact was accepted. Per-task stakes become an explicit planner/operator field, map to the existing economy/champion router plus generic `low|med|high` provider tiers, and are recorded in `decisions.jsonl` with both the basis and the tier actually selected.

## Goals and non-goals

Goals:

- Put the already-shipped Plan Gate, acceptance panel, and verification lifecycle on the default `--execute` path.
- Make missing reviewers, unusable reviews, missing verification contracts, and gate infrastructure failures visible and non-successful.
- Preserve deliberate escape hatches and all non-`--execute` behavior.
- Turn task depth into a deliberate, auditable cost-versus-stakes decision.
- Reuse `Invoke-PlanGate`, `Invoke-AcceptanceGate`, `Select-Capability`, `New-VerifyingSpawner`, and the run decision ledger.

Non-goals:

- No second conductor or workflow engine.
- No automatic merge, rollback, or deletion of an executed run branch.
- No new model IDs in shipped configuration.
- No routing-weight learning from the new stakes fields.
- No direct Research Gate integration in this node; the source shows that it is not currently in the `/baton:go` call graph, and the requested defaults flip names only Plan Gate, acceptance, and verify.

## Source-verified current state

The roadmap's cited `go.md:52` and `go.md:79` references still match exactly. Line 52 says the acceptance result is “an advisory quality verdict, not a rollback,” and lines 78-79 say an understaffed Plan Gate “fails open to `accept`” (`commands/go.md:50-52`, `commands/go.md:74-79`). The source adds two material corrections to the shorthand in d086:

1. Acceptance is already automatic for a non-empty execute diff; `--gate-artifact`/`--gate-diff` are not required on that path.
2. The named panel can already auto-activate when the seeded roster exists, but `/baton:go` does not pass `-FailLoud` or stop on `degraded`.

### Quality-node matrix

| Node | Current activation | Current failure posture | Evidence |
|---|---|---|---|
| Research Gate | Not directly wired into `/baton:go`. The planner prompt merely names `research-gate` as a building block; a planned task is still dispatched as `Task: <desc>` to a model, not as `fleet-research-gate.ps1`. The standalone command must be invoked separately. | Standalone is recommend-only. No worker, non-zero dispatch, or invalid JSON becomes an `inconclusive` fallback rather than a halt. | `scripts/conductor-lib.ps1:316-328`, `scripts/conductor-lib.ps1:446-466`, `scripts/fleet-research-gate.ps1:4-9`, `scripts/research-gate-lib.ps1:235-245` |
| Plan Gate | Opt-in. `fleet-go.ps1` only adds `PlanGate` when `-PlanGate` is present, and the Conductor skips the entire phase otherwise. | Fail-open. Fewer than two unique reviewers returns `verdict=accept`; all-unparsed returns fail-open accept; a thrown gate is caught and the walk proceeds; a failed revise pass walks the original plan. A content `reject` is the one hard stop. | `scripts/fleet-go.ps1:70-86`, `scripts/conductor-lib.ps1:667-711`, `scripts/plan-gate-lib.ps1:162-179`, `scripts/plan-gate-lib.ps1:202-208`, `scripts/conductor-lib.ps1:559-611` |
| Acceptance / named panel | On by default for `--execute` when labor produces a non-empty diff: execute installs `DiffProvider`, and the Conductor gates the produced artifact. Outside execute, literal artifact/diff gating is opt-in. Panel mode auto-activates if `review-roles.yaml` exists and reviewers were not explicitly supplied; Baton Home seeds that file on a new install. | Advisory/fail-open at the Conductor boundary. Diff-provider exceptions, empty artifacts, gate exceptions, and missing verdicts complete without a gate. `Invoke-AcceptanceGate -FailLoud` can mark a panel `degraded`, but it does not change the content verdict; the current Conductor neither passes `-FailLoud` nor consumes `degraded`. `polish` also leaves final status `completed`; only `reject` changes it to `rejected`. | `scripts/fleet-go.ps1:100-115`, `scripts/conductor-lib.ps1:803-836`, `scripts/gate-lib.ps1:367-370`, `scripts/baton-home.ps1:29-35`, `scripts/gate-lib.ps1:432-460` |
| Verify | Opt-in and execute-only. `-Verify` installs the preflight and verifying spawner only inside the `if ($Execute)` block. | Fail-closed only for a task that already declares a profile: unresolved profiles become `plan-invalid`, and failed checks become `verification-failed`. An edit task without a profile delegates to legacy labor and is merely marked `unverified`. | `scripts/fleet-go.ps1:18-24`, `scripts/fleet-go.ps1:100-137`, `scripts/conductor-lib.ps1:713-730`, `scripts/fleet-executor-lib.ps1:244-269`, `scripts/conductor-lib.ps1:778-800` |

### Acceptance is already on the execute path

This is important enough to state separately. `fleet-go.ps1` installs `DiffProvider` unconditionally under `-Execute` (`scripts/fleet-go.ps1:100-115`). The Conductor writes a non-empty result to `changes.diff`, resolves it as the gate artifact, and invokes `Invoke-AcceptanceGate` (`scripts/conductor-lib.ps1:803-826`). The execute integration test proves this without `-GateArtifact` or `-GateDiff`: a plain `-Execute` run asserts both `changes.diff` and an acceptance verdict (`scripts/test-fleet-go-execute.ps1:39-62`).

Therefore the acceptance portion of this node is not “turn acceptance on.” It is:

- make named panel selection explicit (`-Panel`), not dependent on whether a seed happened to exist;
- pass `-FailLoud`;
- treat `degraded`, `polish`, and `reject` as shipping stops;
- preserve diff capture when `--no-gate` disables only the review.

### Current model/depth selection and logging

The planner emits `model_pick` and `est_cost_tier`; normalization retains both (`scripts/conductor-lib.ps1:103-105`). In the execute path, neither field selects the worker. `New-AgenticSpawner` derives only the capability, calls `Select-Capability` with the run-wide `MaxCostTier`, filters agentic fleet candidates, and takes candidate zero (`scripts/fleet-executor-lib.ps1:114-138`). `MaxCostTier` itself defaults to `paid` for the whole run (`scripts/fleet-go.ps1:20-26`).

`Select-Capability` defaults to `SelectionMode=economy` (`scripts/routing-lib.ps1:104-118`) and ranks economy candidates by effective cost tier before learned quality; champion mode instead ranks quality first (`scripts/routing-lib.ps1:244-259`). The per-task `est_cost_tier` is currently used for budget estimation and copied into the run decision record, but not passed to worker selection (`scripts/conductor-lib.ps1:743-765`). `model_pick` is never consumed after normalization.

The actual worker call is deliberately `Invoke-Fleet ... -NoJournal` (`scripts/fleet-executor-lib.ps1:137-138`), so execute labor does **not** add a `model-routing-log.md` fleet line and does not capture the optional named `tier` field supported by `Invoke-Fleet` (`scripts/fleet-lib.ps1:465-512`). The per-run `decisions.jsonl` does record `chose`, `alternatives`, `why`, and `cost_tier` (`scripts/conductor-lib.ps1:188-217`), but that `cost_tier` is the planner's estimate, not the chosen provider's actual tier (`scripts/conductor-lib.ps1:764-767`). Today the “depth” choice is therefore neither applied per task nor fully auditable.

## Proposed behavior

### Default matrix and escape hatches

| Invocation | Plan Gate | Acceptance | Verify |
|---|---|---|---|
| No `--execute`, no existing positive gate flags | Off, unchanged | Off unless `--gate-artifact`/`--gate-diff`, unchanged | Off, unchanged |
| `--execute` | On + fail-loud | Named panel + fail-loud | On; edit tasks require profiles |
| `--execute --no-plan-gate` | Off; exact legacy no-Plan-Gate walk | Default-on panel remains | Default-on verify remains |
| `--execute --no-gate` | Default-on Plan Gate remains | Review off; `changes.diff` still written | Default-on verify remains |
| `--execute --no-verify` | Default-on Plan Gate remains | Default-on panel remains | Verification wrapper/preflight off; legacy labor behavior |

New slash flags and PowerShell parameters:

- `--no-plan-gate` -> `-NoPlanGate`
- `--no-gate` -> `-NoGate`
- `--no-verify` -> `-NoVerify`
- `--stakes low|standard|high` -> `-Stakes low|standard|high` (optional run-wide override)

Existing positive flags remain for standalone/non-execute compatibility:

- `--plan-gate` / `-PlanGate`
- `--gate-artifact` / `-GateArtifact`
- `--gate-diff` / `-GateDiff`
- `-Verify`
- `-PlanRevise:$false`

Contradictory pairs (`-PlanGate -NoPlanGate`, `-Verify -NoVerify`, or an explicit gate artifact/diff with `-NoGate`) are CLI errors: write one clear line with `[Console]::Error.WriteLine(...)` and `exit 2`. Silent precedence would make an escape unauditable.

### `commands/go.md` target

Change the argument hint and engine comments to make execute defaults explicit while preserving the legacy positive flags:

```markdown
argument-hint: "<what you want done>" [--execute] [--repo <path>]
  [--budget <n>] [--max-tier local|free|paid]
  [--stakes low|standard|high]
  [--no-plan-gate] [--no-gate] [--no-verify]
  [--plan-reviewers a,b] [--plan-revise:$false]
  [--gate-artifact <text> | --gate-diff <range>]

# With --execute, add -Execute. Unless explicitly escaped, also add:
#   -PlanGate -PlanGateFailLoud
#   -AcceptanceGate -AcceptancePanel -AcceptanceFailLoud
#   -Verify -RequireVerify
# Map --no-plan-gate/--no-gate/--no-verify to the matching -No* runner switch.
# Add -Stakes low|standard|high only when the operator supplied the override.
```

Update status narration with `plan-gate-degraded`, `acceptance-degraded`, and `needs-polish`. Replace “optional acceptance gate”/“advisory quality verdict” language at `commands/go.md:50-53` with “shipping verdict: branch retained for repair/review; the run is not successful and Baton never auto-merges or rolls back.” Replace the understaffed fail-open note at `commands/go.md:74-79` with the execute/default versus standalone distinction.

### `scripts/fleet-go.ps1` target

Add only CLI-policy parameters here; do not bury execute defaults inside every downstream library:

```powershell
[switch]$NoPlanGate,
[switch]$NoGate,
[switch]$NoVerify,
[ValidateSet('low','standard','high')][string]$Stakes,
```

Compute effective policy once after argument validation:

```powershell
$planGateEnabled = $PlanGate -or ($Execute -and -not $NoPlanGate)
$gateEnabled = (-not $NoGate) -and (
    $Execute -or
    $PSBoundParameters.ContainsKey('GateArtifact') -or
    $PSBoundParameters.ContainsKey('GateDiff')
)
$verifyEnabled = $Verify -or ($Execute -and -not $NoVerify)

if ($planGateEnabled) {
    $go['PlanGate'] = $true
    $go['PlanGateFailLoud'] = [bool]$Execute
}
if ($gateEnabled) {
    $go['AcceptanceGate'] = $true
    if ($Execute) {
        $go['AcceptancePanel'] = $true
        $go['AcceptanceFailLoud'] = $true
    }
}
if ($verifyEnabled -and $Execute) {
    $go['Verify'] = $true
    $go['RequireVerify'] = $true
}
if ($PSBoundParameters.ContainsKey('Stakes')) {
    $go['StakesOverride'] = $Stakes
}
```

`DiffProvider` must remain installed for every execute run, including `-NoGate`, because it is also the producer of `changes.diff`. `-NoGate` disables only the call to `Invoke-AcceptanceGate`; it must not remove proof-by-diff.

The current output block should emit JSON/report first, then return exit code 1 for fail-loud non-success execute statuses. Exit 2 remains reserved for CLI/configuration misuse.

```powershell
$executeFailure = $Execute -and $result.status -in @(
    'failed', 'plan-invalid', 'plan-gate-degraded', 'plan-rejected',
    'verification-failed', 'acceptance-degraded', 'needs-polish', 'rejected'
)
if ($executeFailure) { exit 1 }
```

Budget and destructive interruptions remain structured pauses, not infrastructure failures, so their existing exit behavior stays unchanged.

### `scripts/conductor-lib.ps1` target

Add explicit policy parameters:

```powershell
[switch]$PlanGateFailLoud,
[switch]$AcceptanceGate,
[switch]$AcceptancePanel,
[switch]$AcceptanceFailLoud,
[switch]$Verify,
[switch]$RequireVerify,
[ValidateSet('low','standard','high')][string]$StakesOverride,
```

The Plan Gate boundary consumes degradation before content verdicts:

```powershell
if ($PlanGateFailLoud -and (
    $null -eq $pgRes -or $pgRes.degraded -or $pgRes.fail_open
)) {
    Add-RunEvent -RunDir $RunDir -EventObj (
        New-RunEvent -Kind 'plan-gate' -Level 'error' `
            -Message "PLAN GATE DEGRADED — $($pgRes.reason) — no labor will run"
    )
    return Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-gate-degraded'
}
```

If a `revise` verdict is returned and the one-shot revise pass cannot produce a valid replacement, `-PlanGateFailLoud` must also return `plan-gate-degraded`; walking the rejected original plan would defeat the default. Standalone/legacy Plan Gate calls without `-PlanGateFailLoud` retain today's fail-open behavior.

Keep diff capture separate from review policy:

```powershell
# Always call DiffProvider and write changes.diff when present.
# Only invoke the acceptance reviewer when $AcceptanceGate is true.
if ($AcceptanceGate -and -not [string]::IsNullOrWhiteSpace($art)) {
    $gateArgs = @{
        Artifact = $art
        Task = $plan.goal
        MaxCostTier = $MaxCostTier
        FleetPath = $FleetPath
        ToolsPath = $ToolsPath
    }
    if ($AcceptancePanel) { $gateArgs['Panel'] = $true }
    if ($AcceptanceFailLoud) { $gateArgs['FailLoud'] = $true }
    $gate = Invoke-AcceptanceGate @gateArgs
}
```

Terminal acceptance handling becomes:

```powershell
if ($AcceptanceFailLoud -and (
    [string]::IsNullOrWhiteSpace($art) -or
    $null -eq $gate -or
    -not $gate.verdict -or
    $gate.degraded
)) {
    $finalStatus = 'acceptance-degraded'
} elseif ($gate.verdict -eq 'reject') {
    $finalStatus = 'rejected'
} elseif ($gate.verdict -eq 'polish') {
    $finalStatus = 'needs-polish'
}
```

This is a shipping halt, not rollback. All labor has already run; the branch/worktree stays intact, the report includes the panel result, and Baton does not advertise the run as completed or mergeable.

### `scripts/plan-gate-lib.ps1` target

Mirror the panel's result shape rather than inventing an exception protocol:

```powershell
[switch]$FailLoud

$usableReviewers = @($reviews | Where-Object { $_.parsed }).Count
$degraded = $FailLoud -and $usableReviewers -lt 2
$degradedReviewers = @($reviews | Where-Object { -not $_.parsed } |
    ForEach-Object { $_.reviewer })

return [ordered]@{
    verdict = $verdict.verdict
    reason = if ($degraded) {
        "plan gate degraded: only $usableReviewers usable reviewer(s); need 2"
    } else { $verdict.reason }
    # existing fields unchanged
    fail_open = $failOpen
    degraded = [bool]$degraded
    degraded_reviewers = $degradedReviewers
}
```

Definitions under `-FailLoud`:

- fewer than two unique resolved reviewer names;
- fewer than two parsed, successful reviews after dispatch;
- selector/dispatcher/parser infrastructure throws;
- a required revise pass cannot produce a valid revised plan.

Without `-FailLoud`, the standalone `/baton:plan-gate` behavior remains byte-for-byte compatible.

### `scripts/gate-lib.ps1` target

Reuse the shipped `degraded`/`degraded_roles` contract. Tighten one gap: under `-FailLoud`, **any** enabled role that cannot produce a usable review degrades the panel, not only a skipped role or the all-unparsed case. A named panel is a role contract; silently losing one role is understaffing.

```powershell
$unparsedRoles = @($reviews | Where-Object { -not $_.parsed } |
    ForEach-Object { $_.reviewer })
if ($FailLoud -and $unparsedRoles.Count -gt 0) {
    [void]$degradationReasons.Add(
        "unusable review(s): $($unparsedRoles -join ', ')"
    )
}
$degraded = $panelActive -and (
    $noUsableRoles -or $noReviewerRan -or
    ($FailLoud -and $degradationReasons.Count -gt 0)
)
```

Do not convert `degraded` into fake `reject` findings. `verdict` describes reviewed content; `degraded` describes whether the review process was trustworthy. The Conductor consumes both.

### Verification default and require-verify

Reuse the already-specified V4 graduation boundary: execute edit tasks are capabilities `code-gen` or `code-transform`. Under default `-Verify -RequireVerify`, either capability without `verify_profile` is `plan-invalid` before labor and spend. This matches the existing V4 proposal (`docs/superpowers/specs/2026-07-11-verified-labor-v4-telemetry-graduation-design.md:58-82`) and closes the current legacy delegation at `scripts/fleet-executor-lib.ps1:244-269`.

Target preflight addition in the closure built by `scripts/fleet-go.ps1`:

```powershell
if ($RequireVerify -and
    ([string]$tk.capability -in @('code-gen','code-transform')) -and
    [string]::IsNullOrWhiteSpace([string]$tk.verify_profile)) {
    return @{
        ok = $false
        reason = "task $($tk.id) ($($tk.capability)) needs a verify_profile; " +
                 "add one or re-run with --no-verify"
    }
}
```

Concrete fail-loud behavior:

- Missing required profile: `plan-invalid`, no task dispatch, spend 0.
- Unknown/malformed/unresolvable declared profile: existing `plan-invalid`, no task dispatch, spend 0 (`scripts/conductor-lib.ps1:719-729`).
- Check/oracle/scope failure: existing `verification-failed`; current task stops and the whole DAG walk stops (`scripts/conductor-lib.ps1:781-800`).
- `--no-verify`: do not install `VerifyPreflight` or `New-VerifyingSpawner`; restore pre-v1.13 labor behavior exactly.

## Fail-loud contract

### Meaning of degraded/understaffed

| Gate | Degraded/understaffed means | Concrete outcome |
|---|---|---|
| Plan Gate | Fewer than two unique reviewers resolved; fewer than two usable parsed reviews; gate infrastructure throws; required revise pass fails. | Loud error event and report banner; terminal `plan-gate-degraded`; no DAG task runs; execute CLI exits 1. The untouched worktree/branch uses the existing plan-rejection cleanup path. |
| Acceptance panel | Explicit panel has no usable enabled roles; any enabled role has no capable provider; any role dispatch is non-zero/throws/unparseable; diff provider fails or produces no reviewable artifact; gate returns no verdict. | Loud error event/report banner; terminal `acceptance-degraded`; labor branch/worktree remains for diagnosis; no merge/rollback; execute CLI exits 1. |
| Verify | Required edit profile absent; declared contract cannot be frozen; verifier cannot spawn; contract/check/scope/oracle fails. | Preflight cases return `plan-invalid` before labor; runtime cases return `verification-failed` and stop the current task plus the remaining run; execute CLI exits 1; existing evidence files remain. |
| Research Gate | Not part of this node's `/baton:go` wiring. Standalone `inconclusive` remains recommend-only. | No change in this proposal. If research is later made a mandatory pre-plan node, `inconclusive`/no evidence must gain a separate fail-loud contract. |

“Halt” always means halt the current Conductor run. It does not kill unrelated runs or delete an executed branch. Plan Gate/verification preflight halt before labor; task verification halts the current task and remaining DAG; acceptance halts shipping after labor.

## Depth matched to stakes, logged

### Signal and precedence

Add two normalized task fields to the planner schema:

```json
{
  "stakes": "low|standard|high",
  "stakes_basis": "one concrete sentence naming the risk/size signal"
}
```

Precedence:

1. Operator `--stakes low|standard|high` overrides every task and records basis `operator override: --stakes <value>`.
2. Otherwise each execute task must carry planner-supplied `stakes` and non-empty `stakes_basis`.
3. Non-execute and legacy direct-library calls may normalize missing fields to `standard` / `legacy plan omitted stakes`; the new hard requirement applies only to the default execute path.

Planner guidance should classify:

- `low`: narrow, reversible, low-blast-radius work such as isolated docs or a small local transformation;
- `standard`: ordinary feature/bugfix work with bounded repository impact;
- `high`: auth/security/privacy, data/schema migration, release/publish, cross-cutting architecture, or explicitly high-cost-to-reverse work.

Do not attempt post-hoc touched-file scoring before dispatch; the files do not exist yet. `allowed_paths` count can be cited in `stakes_basis` when present, but the deterministic inputs are the task's declared capability/scope/risk plus the optional operator override.

### Minimal mapping

| Stakes | `depth_tier` | Router mode | Per-task cost ceiling |
|---|---|---|---|
| low | `low` | `economy` | min(run `MaxCostTier`, `free`, task `est_cost_tier`) |
| standard | `med` | `economy` | min(run `MaxCostTier`, task `est_cost_tier`) |
| high | `high` | `champion` | run `MaxCostTier` |

This does not force an expensive model for high stakes: champion still chooses the best measured candidate within the operator's cap and may select local/free. It does not force one universal cheap posture either: high stakes deliberately change the ranking objective. The global `--max-tier` remains an absolute ceiling in all cases.

The shipped seed already uses generic `tier_low`, `tier_med`, and `tier_high` fragments for Codex and carries no private model IDs (`references/fleet.yaml:113-130`). For a selected provider that supports the generic named tier, pass `-Tier $depthTier` to `Invoke-Fleet`. If it does not, `depth_applied=false`; provider-level economy/champion selection still applies and the absence is visible rather than silently claimed.

### Routing target

Extend `New-AgenticSpawner` to resolve the policy before `Select-Capability`:

```powershell
$policy = Resolve-TaskDepthPolicy -Task $task -RunMaxCostTier $MaxCostTier `
    -StakesOverride $StakesOverride
$raw = Select-Capability -Capability $cap `
    -MaxCostTier $policy.max_cost_tier `
    -SelectionMode $policy.selection_mode `
    -FleetPath $FleetPath -ToolsPath $ToolsPath
$pick = @($raw | Where-Object { ... })[0]
$res = Invoke-Fleet -Name $pick.name -Prompt $prompt -Path $FleetPath `
    -Tier $policy.depth_tier -NoJournal
```

`Resolve-TaskDepthPolicy` is the only genuinely new policy function in this design. Keep it pure and unit-test it as a table.

### Journal contract

Use the existing per-run `decisions.jsonl`; it is already the Conductor's per-task autonomous-choice ledger. Do not create a fourth journal. Extend `New-RunDecision` with backward-compatible optional fields:

```json
{
  "task_id": "t3",
  "chose": "codex",
  "cost_tier": "paid",
  "stakes": "high",
  "stakes_basis": "security-sensitive authentication change",
  "depth_tier": "high",
  "depth_applied": true,
  "selection_mode": "champion",
  "tier_cap": "paid",
  "selected_cost_tier": "paid"
}
```

Exact semantics:

- `cost_tier`: retain the old planner estimate for reader compatibility.
- `stakes`: resolved low/standard/high decision.
- `stakes_basis`: operator override or planner's concrete basis.
- `depth_tier`: requested generic provider tier (`low|med|high`).
- `depth_applied`: whether the selected provider actually defined that named tier.
- `selection_mode`: `economy|champion` passed to `Select-Capability`.
- `tier_cap`: effective per-task maximum cost tier after all caps.
- `selected_cost_tier`: actual selected candidate's `local|free|paid` tier.

The verifying wrapper must preserve these fields from the final inner result. Add the same compact decision to the report's `## Decisions` line so the choice is visible without opening JSONL.

The global markdown fleet journal remains invocation telemetry and is currently suppressed by `-NoJournal`; this proposal does not overload it with run policy. If cross-run analysis later needs stakes, a reader can fold `runs/*/decisions.jsonl`, as existing run-scoped consumers already do.

## Backward compatibility

- No `--execute`: no default flip. Existing positive Plan Gate, artifact/diff gate, planning, and route-and-discard behavior remain unchanged.
- `--no-plan-gate`, `--no-gate`, and `--no-verify`: each disables only its named default and restores the corresponding legacy path.
- `--no-gate` does not suppress `changes.diff`, branch retention, or proof-by-diff.
- Standalone `/baton:gate` remains advisory unless `--fail-loud` is explicitly supplied.
- Standalone `/baton:plan-gate` remains fail-open unless its CLI later exposes an explicit fail-loud switch.
- Existing `New-RunDecision` readers continue to find the original fields; new fields are additive.
- Existing fleet entries without named tiers continue to dispatch; `depth_applied=false` prevents a false audit claim.
- The positive `-Verify` path remains available, but execute now supplies it automatically unless escaped.

## Implementation task breakdown

1. **Default-policy matrix tests — pure defaults flip, low risk.**  
   Files: `scripts/test-fleet-go-execute.ps1`, `scripts/test-conductor-lib.ps1`.  
   Add hermetic cases for plain execute defaulting Plan Gate/panel/verify on; each `-No*` switch restoring only its legacy node; contradictory flags exiting 2; non-execute unchanged; and `changes.diff` surviving `-NoGate`.

2. **Compute execute defaults and CLI escapes — pure defaults flip, low risk.**  
   Files: `scripts/fleet-go.ps1`, `commands/go.md`.  
   Add parameters, conflict validation, one policy computation block, splat the effective booleans, and document the new status/escape behavior. Do not change downstream standalone defaults.

3. **Plan Gate degraded result and Conductor halt — small fail-policy logic.**  
   Files: `scripts/plan-gate-lib.ps1`, `scripts/conductor-lib.ps1`, `scripts/test-plan-gate-lib.ps1`, `scripts/test-conductor-lib.ps1`.  
   Add `-FailLoud`, `degraded`, and usable-review count; halt on degraded/throw/revise failure under execute; retain legacy fail-open tests without the switch.

4. **Named-panel fail-loud consumption — mostly wiring plus one completeness rule.**  
   Files: `scripts/gate-lib.ps1`, `scripts/conductor-lib.ps1`, `scripts/test-gate-lib.ps1`, `scripts/test-conductor-lib.ps1`.  
   Pass `-Panel -FailLoud`, degrade on any unusable enabled role, add `acceptance-degraded`, and make `polish` a `needs-polish` shipping stop. Preserve content verdict separately from degradation.

5. **Require-verify graduation — existing V4 policy integration, moderate risk.**  
   Files: `scripts/fleet-go.ps1`, `scripts/conductor-lib.ps1`, `scripts/test-fleet-go-execute.ps1`, `scripts/test-conductor-lib.ps1`.  
   Reject unprofiled `code-gen|code-transform` tasks before labor when execute verification is default-on; prove zero dispatch/spend; prove `-NoVerify` restores legacy behavior. Reuse `New-VerifyingSpawner` and `verification-lib.ps1` unchanged unless a failing test shows a contract gap.

6. **Stakes schema and pure mapping — new logic, highest review focus.**  
   Files: `prompts/conductor-planner.txt`, `scripts/conductor-lib.ps1`, `scripts/fleet-executor-lib.ps1`, `scripts/test-conductor-lib.ps1`, `scripts/test-fleet-executor-lib.ps1`.  
   Preserve `stakes`/`stakes_basis` in plan normalization, add `Resolve-TaskDepthPolicy`, apply economy/champion plus tier caps, pass generic named tier when supported, and ensure verification retries preserve the selected policy fields.

7. **Auditable decision record/report — additive schema, low-to-moderate risk.**  
   Files: `scripts/conductor-lib.ps1`, `scripts/test-conductor-lib.ps1`.  
   Add the exact journal fields above, retain legacy `cost_tier`, and assert a serialized decision/report names stakes, basis, depth, cap, and actual selected cost tier.

8. **CLI terminal exit semantics and full regression gate — behavior boundary, moderate risk.**  
   Files: `scripts/fleet-go.ps1`, `scripts/test-fleet-go-execute.ps1`, relevant `scripts/test-*.ps1` suites.  
   Emit artifacts/JSON before exit 1 on execute non-success; retain exit 2 for bad CLI usage and existing pause behavior for budget/destructive guards. Run `python -m pytest kb dashboard -q` and all `scripts/test-*.ps1` suites required by `AGENTS.md`.

## House rules for implementation

- Write text files with `utf8NoBOM`.
- Never name variables `$args`, `$input`, `$event`, `$matches`, `$host`, or `$pid`.
- CLI errors use `[Console]::Error.WriteLine(...)` and `exit 2`; hooks always exit 0.
- Respect the 965-byte shell-argument ceiling. Long prompts ride stdin or a temporary file, never one shell argument.
- Tests never touch real `~/.baton`, `~/.claude`, or `D:\Dev\Grimdex`; use `$env:TEMP` and restore environment/files in `try/finally`.
- Shipped seeds contain generic tiers only and no box-private model IDs.
- No `--execute` means no defaults flip. A `--no-*` escape must restore the corresponding legacy behavior without disabling unrelated evidence or gates.
- Preserve the existing human merge boundary. No gate result merges, deletes, or rolls back a run branch.

## Open questions

1. **Research Gate placement.** d086's narrative spine names a research gate, but the live `/baton:go` path does not invoke it and this task's requested flip names only Plan Gate, acceptance, and verify. Recommendation: keep research out of node #1 and write a separate pre-plan integration proposal; otherwise this is no longer a near-zero wiring change.
2. **Verification escape vocabulary.** The earlier V4 proposal uses `-AllowUnverified`, while this task requests `--no-verify`. Recommendation: use `--no-verify` for the full-node escape now; reserve `--allow-unverified` only if a later design needs verification enabled for profiled tasks while permitting specific unprofiled edit tasks.
3. **Re-gate after automatic plan revision.** Today a revised plan is walked without a second Plan Gate (`commands/go.md:74-78`). Recommendation for this node: halt only when the revise pass fails and keep one-pass/no-re-gate behavior to contain cost and scope. A mandatory confirm pass would be stronger but is additional spend and behavior beyond a defaults flip.
4. **`polish` terminal policy.** This proposal makes `polish` return `needs-polish` rather than `completed`; that is the clearest interpretation of an authoritative acceptance node. If “fail-loud” is intended to cover infrastructure degradation only, keep `polish` completed—but then acceptance remains partly advisory.
5. **Global journal mirror.** The proposal records stakes in run-scoped `decisions.jsonl`, because execute dispatch intentionally uses `-NoJournal`. If operators require a single cross-run stream, add optional `run_id`, `task_id`, `stakes`, and `depth_tier` metadata to `routing-journal.jsonl`; do not append ad hoc fields to the markdown fleet journal without a separate consumer audit.
