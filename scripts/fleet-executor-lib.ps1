#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet Labor Slice 2 (d078): agentic-executor primitives. A throwaway git worktree
  receives the fleet's edits; proof that labor happened is the worktree's diff
  growing (proof-by-diff — no model prose is ever parsed). The run branch is always
  left for the human to merge; nothing here merges or touches the user's checkout.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"     # Invoke-Fleet for the spawner dispatch
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability for the spawner routing
. "$PSScriptRoot/usage-probe-lib.ps1"   # d090 proactive preflight + cache/advisories
. "$PSScriptRoot/verification-lib.ps1"   # Invoke-VerificationContract etc. (d082 V2)

function New-RunWorktree {
    <# Throwaway worktree at <repo-parent>/.baton-worktrees/<run-id> on a new branch
       baton/run-<run-id> off the repo's current HEAD. Returns
       @{ worktree; branch; base_sha }. Throws with a clear message on any git
       failure — callers surface it and exit 2. #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RunId
    )
    & git -C $RepoPath rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "execute: '$RepoPath' is not a git repository" }
    $base = [string](& git -C $RepoPath rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($base)) {
        throw "execute: '$RepoPath' has no commits (HEAD does not resolve)"
    }
    $base = $base.Trim()
    $resolvedRepo = (Resolve-Path -LiteralPath $RepoPath).Path
    $wtRoot = Join-Path (Split-Path $resolvedRepo -Parent) '.baton-worktrees'
    New-Item -ItemType Directory -Force -Path $wtRoot | Out-Null
    $wt = Join-Path $wtRoot $RunId
    $branch = "baton/run-$RunId"
    $out = & git -C $RepoPath worktree add -b $branch $wt HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw "execute: git worktree add failed: $(@($out) -join ' ')" }
    return @{ worktree = $wt; branch = $branch; base_sha = $base }
}

function Get-RunDiff {
    <# Cumulative unified diff of the worktree vs BaseSha, INCLUDING new/untracked
       files: everything is staged first (`add -A`) so `git diff <sha>` sees them —
       the worktree is throwaway, so staging is harmless (spec §7 mandates new files
       appear in changes.diff). Empty string when nothing changed or on git failure
       (fail-open: an unreadable diff means "no provable work", never a crash). #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BaseSha
    )
    & git -C $Worktree add -A 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return '' }
    $out = & git -C $Worktree diff $BaseSha 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (@($out) -join "`n")
}

function Get-WorktreeTreeSha {
    <# SHA of the worktree's current content tree (index tree after `add -A`, via
       `git write-tree` — plumbing only, no commit is created). Two equal shas =
       the tree did not change between calls; this is the spawner's "diff grew"
       primitive, robust even when an instrument makes its own commits. $null on
       git failure. #>
    param([Parameter(Mandatory)][string]$Worktree)
    & git -C $Worktree add -A 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    $sha = [string](& git -C $Worktree write-tree 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) { return $null }
    return $sha.Trim()
}

function Restore-WorktreeTreeSnapshot {
    <# Restore the isolated run worktree to a previously captured tree. Refuses
       to clean unless -Worktree resolves to that repository's top level. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$TreeSha
    )
    try {
        $resolved = (Resolve-Path -LiteralPath $Worktree -ErrorAction Stop).Path.Replace('/', '\').TrimEnd('\')
        $top = [string](& git -C $resolved rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($top)) { return $false }
        $top = $top.Trim().Replace('/', '\').TrimEnd('\')
        if (-not $top.Equals($resolved, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        & git -C $resolved cat-file -e "$TreeSha`^{tree}" 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        & git -C $resolved restore --source=$TreeSha --staged --worktree -- . 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        & git -C $resolved clean -fd -- . 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        return ((Get-WorktreeTreeSha -Worktree $resolved) -eq $TreeSha)
    } catch {
        return $false
    }
}

function Get-AgenticUsageObservation {
    <# Consume Invoke-Fleet's attached observation, or classify an injected
       dispatch result exactly once for hermetic spawner tests. #>
    param(
        $Result,
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)][string]$UsagePath,
        [Nullable[long]]$PromptBytes = $null
    )
    if ($null -ne $Result) {
        if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('usage_observation')) {
            return $Result.usage_observation
        }
        if ($null -ne $Result.PSObject.Properties['usage_observation']) {
            return $Result.usage_observation
        }
    }
    $exitCode = if ($null -ne $Result) { [int]$Result.exit_code } else { -1 }
    $stdout = if ($null -ne $Result) { [string]$Result.stdout } else { '' }
    $stderr = if ($null -ne $Result) { [string]$Result.stderr } else { 'dispatch returned no result' }
    return Register-UsageFailure -Worker $Worker -ExitCode $exitCode -Stdout $stdout -Stderr $stderr -UsagePath $UsagePath -PromptBytes $PromptBytes
}

function Test-ProviderAgentic {
    <# Edit-eligibility (d078, concept-anchored per d025): the optional `agentic`
       field is authoritative when present; absent, eligibility is inferred from
       platform ∈ {claude, codex, gemini}. Chat/local/github providers are filtered
       out of edit tasks (their diff-apply path is Slice 3). Accepts either a fleet
       provider hashtable or a Select-Capability candidate object. #>
    param([Parameter(Mandatory)]$Provider)
    # d091: an explicit marker cannot grant edit powers to transports without
    # an agentic filesystem harness. Legacy test objects with no kind retain
    # the pre-ABI inference behavior.
    if ([string]$Provider.kind -in @('http', 'stdio-json')) { return $false }
    if ($null -ne $Provider.agentic) { return [bool]$Provider.agentic }
    return (([string]$Provider.platform) -in @('claude', 'codex', 'gemini'))
}

function Get-CapabilityCostTierFloor {
    <# Cheapest cost_tier among enabled fleet providers that claim $Capability.
       For code-gen/code-transform, only edit-eligible providers count
       (Test-ProviderAgentic). Also applies Select-Capability context floors
       (Get-CapabilityFloors + known-too-small context). Returns
       'local'|'free'|'paid'|'UNAVAILABLE'. Fail-soft: missing/unparseable
       fleet => 'UNAVAILABLE', never throws. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
    )
    try {
        if ([string]::IsNullOrWhiteSpace($FleetPath) -or -not (Test-Path -LiteralPath $FleetPath)) {
            return 'UNAVAILABLE'
        }
        $providers = @(Read-Fleet -Path $FleetPath)
        $generalCaps = @(Get-GeneralCapabilities -FleetPath $FleetPath)
        # Mirror Select-Capability (routing-lib ~153-155). Fail-soft if floors helper
        # is out of scope (routing-lib normally in scope via this file's header).
        $capFloors = @{}
        if (Get-Command Get-CapabilityFloors -ErrorAction SilentlyContinue) {
            $capFloors = Get-CapabilityFloors -FleetPath $FleetPath
        }
        $bestRank = 99
        $bestTier = $null
        foreach ($prov in $providers) {
            if ($prov.enabled -ne $true) { continue }
            $claims = $prov.capabilities
            $claimsCap = if ($null -ne $claims) { @($claims) -contains $Capability }
                         else { $generalCaps -contains $Capability }
            if (-not $claimsCap) { continue }
            if ($Capability -in @('code-gen', 'code-transform')) {
                if (-not (Test-ProviderAgentic -Provider $prov)) { continue }
            }
            # Same as Select-Capability: known-too-small context disqualifies;
            # unknown/missing context never does.
            if ($capFloors.ContainsKey($Capability) -and $prov.context) {
                if ([int]$prov.context -lt $capFloors[$Capability]) { continue }
            }
            $tierName = [string]$prov.cost_tier
            if ($tierName -notin @('local', 'free', 'paid')) { continue }
            $rank = Get-CostTierRank $tierName
            if ($rank -lt $bestRank) { $bestRank = $rank; $bestTier = $tierName }
        }
        if ($null -eq $bestTier) { return 'UNAVAILABLE' }
        return $bestTier
    } catch {
        return 'UNAVAILABLE'
    }
}

function Format-ZeroCandidateWhy {
    <# Human-readable failure for the New-AgenticSpawner zero-candidate seam (#127).
       Names the stakes/tier collision and the cheapest eligible floor — message
       only; does not change routing. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$TierCap,
        [Parameter(Mandatory)][string]$Stakes,
        [Parameter(Mandatory)][string]$Floor
    )
    return "capability ${Capability}: no eligible provider at tier <=${TierCap} (stakes ${Stakes} caps tier; cheapest eligible = ${Floor}). Remedies: raise task est_cost_tier, or re-run with --stakes standard|high."
}

function Test-ProviderDepthTier {
    <# Capability probe for depth_applied: true when the selected provider CAN
       apply a safe named tier fragment on the CLI path (defines a non-empty
       tier_* fragment and the template consumes {{tier_args}}). Resolved
       before dispatch — not "this argv contained the fragment". #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][ValidateSet('low','med','high')][string]$DepthTier
    )
    if ([string]$Provider.kind -ne 'cli') { return $false }
    if (-not ([string]$Provider.command_template).Contains('{{tier_args}}')) { return $false }
    if (-not $Provider.ContainsKey("tier_$DepthTier")) { return $false }
    return -not [string]::IsNullOrWhiteSpace((Get-FleetProviderTier -Provider $Provider -Tier $DepthTier))
}

function Remove-RunWorktree {
    <# Explicit discard of the worktree DIRECTORY only. The run branch is
       intentionally KEPT so the human can still inspect or merge the work.
       Throws on git failure. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$Force
    )
    $extra = @(); if ($Force) { $extra += '--force' }
    $out = & git -C $RepoPath worktree remove @extra $Worktree 2>&1
    if ($LASTEXITCODE -ne 0) { throw "execute: git worktree remove failed: $(@($out) -join ' ')" }
}

function Resolve-TaskDepthPolicy {
    <# Pure d086 PR-B policy: resolve planner/operator stakes into a generic
       provider depth, router objective, and effective per-task cost ceiling. #>
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][ValidateSet('local','free','paid')][string]$RunMaxCostTier,
        [ValidateSet('low','standard','high')][string]$StakesOverride
    )
    $hasOverride = $PSBoundParameters.ContainsKey('StakesOverride')
    $stakes = if ($hasOverride) { $StakesOverride }
              elseif ([string]::IsNullOrWhiteSpace([string]$Task.stakes)) { 'standard' }
              else { [string]$Task.stakes }
    $basis = if ($hasOverride) { "operator override: --stakes $StakesOverride" }
             elseif ([string]::IsNullOrWhiteSpace([string]$Task.stakes)) { 'legacy plan omitted stakes' }
             else { [string]$Task.stakes_basis }
    $estimate = if ([string]$Task.est_cost_tier -in @('local','free','paid')) {
        [string]$Task.est_cost_tier
    } else { $RunMaxCostTier }
    $tiers = @('local','free','paid')
    $minTier = {
        param([string[]]$Values)
        $rank = ($Values | ForEach-Object { [array]::IndexOf($tiers, $_) } | Measure-Object -Minimum).Minimum
        return $tiers[[int]$rank]
    }.GetNewClosure()

    switch ($stakes) {
        'low' {
            $depth = 'low'; $mode = 'economy'
            $cap = & $minTier @($RunMaxCostTier, 'free', $estimate)
        }
        'high' {
            $depth = 'high'; $mode = 'champion'; $cap = $RunMaxCostTier
        }
        default {
            $stakes = 'standard'; $depth = 'med'; $mode = 'economy'
            $cap = & $minTier @($RunMaxCostTier, $estimate)
        }
    }
    return [ordered]@{
        stakes = $stakes
        stakes_basis = $basis
        depth_tier = $depth
        selection_mode = $mode
        max_cost_tier = $cap
    }
}

function New-AgenticResultBase {
    param(
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][string]$FleetPath
    )
    $providerRow = Get-FleetProvider -Name ([string]$Candidate.name) -Path $FleetPath
    $canApplyDepth = ($null -ne $providerRow) -and (Test-ProviderDepthTier -Provider $providerRow -DepthTier $Policy.depth_tier)
    return @{
        stakes = $Policy.stakes; stakes_basis = $Policy.stakes_basis; depth_tier = $Policy.depth_tier
        selection_mode = $Policy.selection_mode; tier_cap = $Policy.max_cost_tier
        depth_applied = [bool]$canApplyDepth; selected_cost_tier = [string]$Candidate.cost_tier
    }
}

function Invoke-AgenticDispatchAttempt {
    param(
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$DepthTier,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$FleetPath,
        [Parameter(Mandatory)][string]$UsagePath,
        [scriptblock]$Dispatcher
    )
    Push-Location -LiteralPath $Worktree
    try {
        $attemptResult = if ($Dispatcher) { & $Dispatcher $Candidate $Prompt $DepthTier }
                         else { Invoke-Fleet -Name $Candidate.name -Prompt $Prompt -Path $FleetPath -Tier $DepthTier -UsagePath $UsagePath -NoJournal }
        if ($null -eq $attemptResult) {
            return @{ result = @{ stdout=''; stderr='dispatch returned no result'; exit_code=-1; duration_s=0 }; dispatch_error='dispatch returned no result' }
        }
        return @{ result = $attemptResult; dispatch_error = '' }
    } catch {
        return @{ result = @{ stdout=''; stderr=$_.Exception.Message; exit_code=-1; duration_s=0 }; dispatch_error=$_.Exception.Message }
    } finally {
        Pop-Location
    }
}

function Resolve-AgenticSubstituteCandidates {
    <# Shared quality-first re-resolution for proactive and reactive usage hops. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)]$OriginalCandidate,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$AttemptedProviders,
        [Parameter(Mandatory)][hashtable]$PolicyArgs,
        [Parameter(Mandatory)][string]$FleetPath,
        [Parameter(Mandatory)][string]$ToolsPath,
        [Parameter(Mandatory)][string]$UsagePath,
        [Parameter(Mandatory)][string]$RatingsPath,
        [Parameter(Mandatory)][string]$JournalPath
    )
    $retryPolicy = Resolve-TaskDepthPolicy @PolicyArgs
    $retryRaw = Select-Capability -Capability $Capability -MaxCostTier $retryPolicy.max_cost_tier `
        -SelectionMode $retryPolicy.selection_mode -FleetPath $FleetPath -ToolsPath $ToolsPath `
        -UsagePath $UsagePath -RatingsPath $RatingsPath -JournalPath $JournalPath
    $eligible = @($retryRaw | Where-Object {
        ($null -ne $_) -and ([string]$_.source -eq 'fleet') -and
        (Test-ProviderAgentic -Provider $_) -and
        (-not $AttemptedProviders.Contains([string]$_.name)) -and
        ([double]$_.quality -ge [double]$OriginalCandidate.quality)
    })
    return [ordered]@{ policy = $retryPolicy; candidates = @($eligible) }
}

function Sort-ContextOverflowCandidates {
    <# Soft preference: larger declared max_prompt_bytes first. Missing data is
       treated as 0 and does not hard-fail the hop — stable by original index.
       Prefers the value already on the Select-Capability candidate; falls back
       to a fleet.yaml re-read when the field is absent.
       Returns a flat object[] (NOT unary-comma nested) so callers can take [0]. #>
    param(
        [AllowEmptyCollection()][object[]]$Candidates = @(),
        [Parameter(Mandatory)][string]$FleetPath
    )
    $list = [System.Collections.Generic.List[object]]::new()
    $idx = 0
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $ceiling = [long]0
        $raw = $null
        if ($null -ne $candidate.PSObject.Properties['max_prompt_bytes']) {
            $raw = $candidate.max_prompt_bytes
        }
        if (($null -eq $raw -or [string]::IsNullOrWhiteSpace([string]$raw)) -and $FleetPath) {
            $provider = Get-FleetProvider -Name ([string]$candidate.name) -Path $FleetPath
            if ($null -ne $provider) {
                if ($provider -is [System.Collections.IDictionary] -and $provider.Contains('max_prompt_bytes')) {
                    $raw = $provider['max_prompt_bytes']
                } elseif ($null -ne $provider.PSObject.Properties['max_prompt_bytes']) {
                    $raw = $provider.max_prompt_bytes
                }
            }
        }
        if ($null -ne $raw -and -not [string]::IsNullOrWhiteSpace([string]$raw)) {
            $parsed = [long]0
            if ([long]::TryParse([string]$raw, [ref]$parsed) -and $parsed -gt 0) {
                $ceiling = $parsed
            }
        }
        $candidate | Add-Member -NotePropertyName context_capacity_bytes -NotePropertyValue $ceiling -Force
        $candidate | Add-Member -NotePropertyName context_sort_index -NotePropertyValue $idx -Force
        $list.Add([pscustomobject]@{
            candidate = $candidate
            cap = $ceiling
            idx = $idx
        })
        $idx++
    }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($row in ($list | Sort-Object @{ e = { -[long]$_.cap } }, @{ e = { [int]$_.idx } })) {
        $out.Add($row.candidate)
    }
    return $out.ToArray()
}

function Sort-UsageSurplusCandidates {
    <# Apply only a tiny score preference from fresh cached adapter data. The
       existing router already enforced cost/stakes/quality eligibility. #>
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][string]$FleetPath,
        [Parameter(Mandatory)][string]$ProbeCachePath,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )
    $hasPreference = $false
    $candidateIndex = 0
    $ranked = foreach ($candidate in @($Candidates)) {
        $preference = [double]0
        $reason = ''
        $provider = Get-FleetProvider -Name ([string]$candidate.name) -Path $FleetPath
        if ($null -ne $provider -and $null -ne $provider.usage_policy -and $provider.usage_policy.probe -eq $true) {
            $snapshot = Get-FreshUsageProbeCache -Worker ([string]$candidate.name) -CachePath $ProbeCachePath -Now $Now
            $surplus = Test-UsageSurplusSpend -Provider $provider -Snapshot $snapshot -Now $Now
            if ($surplus.apply) {
                $preference = [double]$surplus.preference
                $reason = [string]$surplus.reason
                $hasPreference = $true
            }
        }
        $candidate | Add-Member -NotePropertyName usage_preference -NotePropertyValue $preference -Force
        $candidate | Add-Member -NotePropertyName usage_preference_reason -NotePropertyValue $reason -Force
        $candidate | Add-Member -NotePropertyName usage_adjusted_score -NotePropertyValue ([double]$candidate.score - $preference) -Force
        $candidate | Add-Member -NotePropertyName usage_original_index -NotePropertyValue $candidateIndex -Force
        $candidateIndex++
        $candidate
    }
    if (-not $hasPreference) { return ,([object[]]@($ranked)) }
    $sorted = @($ranked | Sort-Object @{e={ [double]$_.usage_adjusted_score }}, @{e={ [int]$_.usage_original_index }})
    return ,([object[]]$sorted)
}

function Get-UsagePreflightEvidenceWindow {
    param([Parameter(Mandatory)]$Decision)
    $ranked = @($Decision.checked | Sort-Object {
        $cap = [double]$_.cap
        if ($cap -le 0) { return [double]::PositiveInfinity }
        return -([double]$_.used_pct / $cap)
    })
    if ($ranked.Count -eq 0) { return $null }
    return $ranked[0]
}

# ---- Task-output bus (#115 slice 1 / engine-expressiveness) ----
# Capture structured residue from each worker attempt and inject upstream
# depends_on outputs into the next task's prompt. Spawner-side only.

$script:TaskOutputBusPerCapBytes = 8192
$script:TaskOutputBusTotalInputBytes = 24576
$script:TaskOutputBusTruncMarker = '(truncated)'

# Engine-owned rework (#128 slice 2 / engine-expressiveness §4). Mechanical ceiling
# enforced in code, never by prompt text. Default 1 = old single evidence-informed
# retry subsumed as rework cycle #1. AbsoluteMaxRework is the hard code backstop
# (spec §4.3): LLM-authored task.max_rework can never raise above it.
$script:DefaultMaxRework = 1
$script:AbsoluteMaxRework = 3
$script:ReworkableFailureCategories = @(
    'check-failed', 'check-timeout', 'no-change',
    'expected-file-missing', 'expected-file-empty', 'expected-file-unchanged'
)

function Get-TaskOutputInstructionBlock {
    <# Short trailing instruction, identical on every worker prompt seam. #>
    return @(
        '## Task output'
        'End your reply with a ## Task output section holding the structured residue the next task needs:'
        'research -> file paths + facts; review -> verdict + numbered fix list; implement -> what changed + flags.'
    ) -join "`n"
}

function Limit-Utf8TextWithMarker {
    <# Cap text at MaxBytes (UTF-8). When cut, append an explicit marker — never silent. #>
    param(
        [AllowEmptyString()][AllowNull()][string]$Text = '',
        [int]$MaxBytes = $script:TaskOutputBusPerCapBytes,
        [string]$Marker = $script:TaskOutputBusTruncMarker
    )
    $enc = [System.Text.Encoding]::UTF8
    $raw = if ($null -eq $Text) { '' } else { [string]$Text }
    if ($enc.GetByteCount($raw) -le $MaxBytes) { return $raw }
    $markerText = "`n$Marker"
    $markerBytes = $enc.GetByteCount($markerText)
    $budget = [Math]::Max(0, $MaxBytes - $markerBytes)
    $cut = $raw
    while ($enc.GetByteCount($cut) -gt $budget -and $cut.Length -gt 0) {
        $cut = $cut.Substring(0, [Math]::Max(0, $cut.Length - 16))
    }
    # Final safety: multibyte edge — drop one char at a time if still over.
    while ($enc.GetByteCount($cut) -gt $budget -and $cut.Length -gt 0) {
        $cut = $cut.Substring(0, $cut.Length - 1)
    }
    return $cut + $markerText
}

function Get-TaskOutputResidue {
    <# Extract the last ## Task output section from worker stdout. Fail-soft: if the
       heading is absent, take the whole stdout as the tail. Always size-capped. #>
    param(
        [AllowEmptyString()][AllowNull()][string]$Stdout = '',
        [int]$MaxBytes = $script:TaskOutputBusPerCapBytes
    )
    $text = if ($null -eq $Stdout) { '' } else { [string]$Stdout }
    $marker = '## Task output'
    $idx = $text.LastIndexOf($marker, [System.StringComparison]::Ordinal)
    $section = if ($idx -ge 0) { $text.Substring($idx) } else { $text }
    return (Limit-Utf8TextWithMarker -Text $section -MaxBytes $MaxBytes)
}

function Test-TaskBusIdSafe {
    <# Planner-supplied task ids must be single path segments: alphanumerics, dot,
       underscore, hyphen only — never '.'/'..' and never path separators. #>
    param([AllowEmptyString()][AllowNull()][string]$Id = '')
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    if ($Id -eq '.' -or $Id -eq '..') { return $false }
    return [bool]($Id -match '^[A-Za-z0-9._-]+$')
}

function Resolve-TaskBusContainedPath {
    <# Resolve <RunDir>/tasks/<TaskId>[/output.md] only if the final full path stays
       under <RunDir>/tasks. Returns $null on unsafe id or containment failure. #>
    param(
        [string]$RunDir,
        [string]$TaskId,
        [switch]$OutputFile
    )
    if ([string]::IsNullOrWhiteSpace($RunDir)) { return $null }
    if (-not (Test-TaskBusIdSafe -Id $TaskId)) { return $null }
    try {
        $tasksRoot = [System.IO.Path]::GetFullPath((Join-Path $RunDir 'tasks'))
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $tasksRoot $TaskId))
        if ($OutputFile) {
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $candidate 'output.md'))
        }
        $prefix = if ($tasksRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar) -or
            $tasksRoot.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
            $tasksRoot
        } else {
            $tasksRoot + [System.IO.Path]::DirectorySeparatorChar
        }
        # Contained if equal to tasks root (task dir only, never for file) or under it.
        $ok = $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $ok -and -not $OutputFile) {
            $ok = $candidate.Equals($tasksRoot, [System.StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $ok) { return $null }
        return $candidate
    } catch {
        return $null
    }
}

function Write-TaskBusOutput {
    <# Persist captured residue to <RunDir>/tasks/<id>/output.md (utf8NoBOM).
       Fail-soft: missing RunDir/TaskId, unsafe TaskId, or IO errors never throw.
       Overwrites on each attempt so the latest attempt (success or fail) is what
       dependents see. Unsafe TaskId skips with a warning (no path traversal). #>
    [CmdletBinding()]
    param(
        [string]$RunDir,
        [string]$TaskId,
        [AllowEmptyString()][AllowNull()][string]$Stdout = ''
    )
    if ([string]::IsNullOrWhiteSpace($RunDir) -or [string]::IsNullOrWhiteSpace($TaskId)) { return }
    $outPath = Resolve-TaskBusContainedPath -RunDir $RunDir -TaskId $TaskId -OutputFile
    if ($null -eq $outPath) {
        Write-Warning "task-output-bus: rejecting unsafe TaskId '$TaskId' (write skipped)"
        return
    }
    try {
        $taskDir = Split-Path -Parent $outPath
        New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
        $body = Get-TaskOutputResidue -Stdout $Stdout
        Set-Content -LiteralPath $outPath -Value $body -Encoding utf8NoBOM
    } catch { }
}

function Get-TaskBusInputBlock {
    <# Build the dependency-injection preamble for a task. One ## Inputs from <id>
       section per depends_on entry (order preserved; duplicate ids deduped, first
       wins). Per-dep and total caps apply. Missing/unsafe output.md -> placeholder
       line, never throw. #>
    param(
        [string]$RunDir,
        [string[]]$DependsOn = @(),
        [int]$PerCapBytes = $script:TaskOutputBusPerCapBytes,
        [int]$TotalCapBytes = $script:TaskOutputBusTotalInputBytes
    )
    $rawDeps = @($DependsOn | Where-Object { $_ } | ForEach-Object { [string]$_ })
    # Dedupe: first occurrence wins, order preserved.
    $seen = @{}
    $depIds = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $rawDeps) {
        if ($seen.ContainsKey($d)) { continue }
        $seen[$d] = $true
        $depIds.Add($d)
    }
    if ($depIds.Count -eq 0) { return '' }
    $enc = [System.Text.Encoding]::UTF8
    $sections = [System.Collections.Generic.List[object]]::new()
    foreach ($depId in $depIds) {
        $body = '(no output was produced)'
        $path = Resolve-TaskBusContainedPath -RunDir $RunDir -TaskId $depId -OutputFile
        if ($null -ne $path -and (Test-Path -LiteralPath $path)) {
            try {
                $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
                if ($null -eq $raw) { $raw = '' }
                $body = Limit-Utf8TextWithMarker -Text $raw -MaxBytes $PerCapBytes
            } catch {
                $body = '(no output was produced)'
            }
        }
        $block = "## Inputs from $depId`n$body"
        $sections.Add([pscustomobject]@{ id = $depId; text = $block; bytes = $enc.GetByteCount($block) })
    }
    # Total-cap: drop oldest-first (front of depends_on order) until under budget.
    $dropped = [System.Collections.Generic.List[string]]::new()
    $total = 0L
    foreach ($s in $sections) { $total += $s.bytes }
    # Account for blank-line joiners between kept sections (~2 bytes each).
    $joinBudget = if ($sections.Count -gt 1) { 2L * ($sections.Count - 1) } else { 0L }
    $total += $joinBudget
    while ($sections.Count -gt 0 -and $total -gt $TotalCapBytes) {
        $gone = $sections[0]
        $sections.RemoveAt(0)
        $dropped.Add([string]$gone.id)
        $total = 0L
        foreach ($s in $sections) { $total += $s.bytes }
        $joinBudget = if ($sections.Count -gt 1) { 2L * ($sections.Count - 1) } else { 0L }
        $total += $joinBudget
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($dropped.Count -gt 0) {
        $parts.Add("(inputs truncated: $($dropped -join ', '))")
    }
    foreach ($s in $sections) { $parts.Add([string]$s.text) }
    if ($parts.Count -eq 0) { return '' }
    return ($parts -join "`n`n")
}

function Add-TaskOutputInstruction {
    <# Append the shared instruction block once (idempotent if already present). #>
    param([AllowEmptyString()][AllowNull()][string]$Prompt = '')
    $base = if ($null -eq $Prompt) { '' } else { [string]$Prompt }
    $block = Get-TaskOutputInstructionBlock
    # Exact-block guard only: a bare `## Task output` heading appears in injected
    # dependency residue and must NOT suppress the instruction block (#115 review).
    if ($base.IndexOf($block, [System.StringComparison]::Ordinal) -ge 0) { return $base }
    if ([string]::IsNullOrEmpty($base)) { return $block }
    return $base.TrimEnd() + "`n`n" + $block
}

function Build-AgenticWorkerPrompt {
    <# Full worker prompt: optional bus inputs + Task: desc + output instruction. #>
    param(
        [AllowEmptyString()][AllowNull()][string]$TaskDesc = '',
        [AllowEmptyString()][AllowNull()][string]$InputBlock = ''
    )
    $desc = if ($null -eq $TaskDesc) { '' } else { [string]$TaskDesc }
    $core = "Task: $desc"
    if (-not [string]::IsNullOrWhiteSpace($InputBlock)) {
        # ADVISORY DATA, NOT AUTHORITY — see call site comment in New-AgenticSpawner.
        $core = $InputBlock.TrimEnd() + "`n`n" + $core
    }
    return (Add-TaskOutputInstruction -Prompt $core)
}

function New-AgenticSpawner {
    <# Factory: returns a scriptblock matching Invoke-Conductor's -Spawner contract
       (param($task) -> @{ ok; spend; chose; why; alternatives }). Per task: route the
       capability, FILTER to edit-eligible providers, dispatch with cwd = the worktree
       (Push-Location/Pop-Location around the call), and prove labor by the worktree
       content tree changing (proof-by-diff, d078). Precedence: nonzero exit -> fail;
       tree changed -> ok; exit 0 + no change -> ok with why 'no changes'.
       -Dispatcher injects a fake instrument for hermetic tests. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$RunDir,
        [scriptblock]$Dispatcher,
        [ValidateSet('low','standard','high')][string]$StakesOverride,
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl'),
        # Ratings/journal under BATON_HOME so quality_first is hermetic in tests (not host ~/.claude).
        [string]$RatingsPath = (Join-Path (Get-BatonHome) 'routing-ratings.jsonl'),
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'),
        [ValidateSet('quality_first','never')][string]$FailoverPolicy = 'quality_first',
        [scriptblock]$ProbeTransport,
        [string]$ProbeCachePath = (Join-Path (Get-BatonHome) 'usage-probe-cache.jsonl'),
        [string]$FleetJournalPath = (Join-Path (Get-BatonHome) 'model-routing-log.md'),
        [scriptblock]$ProbeClock
    )
    $hasStakesOverride = $PSBoundParameters.ContainsKey('StakesOverride')
    return {
        param($task)
        $cap = if ($task.capability) { $task.capability } else { 'reasoning' }
        $policyArgs = @{ Task = $task; RunMaxCostTier = $MaxCostTier }
        if ($hasStakesOverride) { $policyArgs.StakesOverride = $StakesOverride }
        $policy = Resolve-TaskDepthPolicy @policyArgs
        # Select-Capability returns via `,([object[]]$ranked)` (comma-operator array
        # preservation, correct for callers doing a direct `$x = Select-Capability ...`
        # assignment with 0/1 results). Piping that return straight into Where-Object
        # does NOT unroll it — PowerShell hands the whole candidate array to Where-Object
        # as a single $_. Capture to a plain variable first (direct assignment unwraps
        # correctly) and filter the variable, not the call, to get real per-candidate
        # enumeration.
        $raw = Select-Capability -Capability $cap -MaxCostTier $policy.max_cost_tier `
            -SelectionMode $policy.selection_mode -FleetPath $FleetPath -ToolsPath $ToolsPath `
            -UsagePath $UsagePath -RatingsPath $RatingsPath -JournalPath $JournalPath
        # Edit dispatch is fleet-only (Invoke-Fleet resolves names against fleet.yaml);
        # tools.yaml candidates cannot take edit dispatch even if they infer agentic
        # via a platform field, so require source='fleet' before the agentic test.
        $cands = @($raw | Where-Object { ($null -ne $_) -and ([string]$_.source -eq 'fleet') -and (Test-ProviderAgentic -Provider $_) })
        if ($cands.Count -lt 1) {
            # Message-only remedy (#127): name the stakes/tier collision; do NOT auto-escalate.
            $floor = Get-CapabilityCostTierFloor -Capability $cap -FleetPath $FleetPath
            $whyZero = Format-ZeroCandidateWhy -Capability $cap -TierCap $policy.max_cost_tier `
                -Stakes $policy.stakes -Floor $floor
            return @{
                ok = $false; spend = 0.0; chose = ''; why = $whyZero; alternatives = @()
                stakes = $policy.stakes; stakes_basis = $policy.stakes_basis; depth_tier = $policy.depth_tier
                selection_mode = $policy.selection_mode; tier_cap = $policy.max_cost_tier
                depth_applied = $false; selected_cost_tier = ''
            }
        }
        $preflightNow = try {
            if ($ProbeClock) { [datetimeoffset](& $ProbeClock) } else { [datetimeoffset]::UtcNow }
        } catch { [datetimeoffset]::UtcNow }
        $surplusRanked = Sort-UsageSurplusCandidates -Candidates $cands -FleetPath $FleetPath `
            -ProbeCachePath $ProbeCachePath -Now $preflightNow
        $cands = @($surplusRanked)
        $pick = $cands[0]
        $alts = @($cands | Select-Object -Skip 1 | ForEach-Object { $_.name })
        $resultBase = New-AgenticResultBase -Candidate $pick -Policy $policy -FleetPath $FleetPath
        # Task-output bus (#115): inject depends_on outputs as ADVISORY DATA, NOT AUTHORITY.
        # Verification contracts still freeze from the base revision; a wrong/poisoned
        # output can waste a task but cannot widen allowed_paths or weaken the oracle.
        $depIds = @()
        if ($null -ne $task.depends_on) { $depIds = @($task.depends_on | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        $busInputs = Get-TaskBusInputBlock -RunDir $RunDir -DependsOn $depIds
        $prompt = Build-AgenticWorkerPrompt -TaskDesc ([string]$task.desc) -InputBlock $busInputs
        $attemptedProviders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$attemptedProviders.Add([string]$pick.name)
        $preflightRerouted = $false
        $hopLine = ''
        $advisoryLines = [System.Collections.Generic.List[string]]::new()

        $providerRow = Get-FleetProvider -Name ([string]$pick.name) -Path $FleetPath
        $canProbe = ($null -ne $providerRow) -and ($null -ne $providerRow.usage_policy) -and
            ($providerRow.usage_policy.probe -eq $true) -and ([string]$providerRow.kind -eq 'cli') -and
            ([string]$providerRow.platform -eq 'codex')
        if ($canProbe) {
            $snapshot = Get-CodexUsageProbe -Worker ([string]$pick.name) -Transport $ProbeTransport `
                -CachePath $ProbeCachePath -Now $preflightNow -TimeoutSeconds 20 -TtlSeconds 600
            if ($null -ne $snapshot) {
                $capDecision = Get-UsageProbeCapDecision -Provider $providerRow -Observations @($snapshot.observations)
                $evidenceWindow = Get-UsagePreflightEvidenceWindow -Decision $capDecision
                $usageRows = Read-UsageJournal -Path $UsagePath
                $monthly = Get-MonthlyUsagePaceAdvisory -Worker ([string]$pick.name) `
                    -UsagePolicy $providerRow.usage_policy -Rows $usageRows -Now $preflightNow
                if ($monthly.advisory -and $monthly.line) { $advisoryLines.Add([string]$monthly.line) }
                $fitObservation = @($snapshot.observations | Where-Object { $_.scope -eq 'five_hour' } | Select-Object -First 1)
                if ($fitObservation.Count -gt 0) {
                    $tokenStats = Get-FleetMedianDispatchTokens -Worker ([string]$pick.name) `
                        -JournalPath $FleetJournalPath -SampleSize 20
                    $fitLine = Get-UsageFitAdvisory -Worker ([string]$pick.name) `
                        -Observation $fitObservation[0] -TokenStats $tokenStats
                    if ($fitLine) { $advisoryLines.Add([string]$fitLine) }
                }

                if ($capDecision.over_cap) {
                    Add-UsageProbeLimitedRows -Worker ([string]$pick.name) -Decision $capDecision -UsagePath $UsagePath
                    $originalPick = $pick
                    $crossings = @($capDecision.windows)
                    $substitution = Resolve-AgenticSubstituteCandidates -Capability $cap -OriginalCandidate $originalPick `
                        -AttemptedProviders $attemptedProviders -PolicyArgs $policyArgs -FleetPath $FleetPath `
                        -ToolsPath $ToolsPath -UsagePath $UsagePath -RatingsPath $RatingsPath -JournalPath $JournalPath
                    $preflightCandidates = @($substitution.candidates)
                    if ($preflightCandidates.Count -lt 1) {
                        Add-UsagePreflightEvent -Worker ([string]$originalPick.name) -Outcome held `
                            -WindowDecision $crossings -UsagePath $UsagePath -Reason 'soft_cap' -Timestamp $preflightNow.ToString('o')
                        $holdLine = Format-UsagePreflightLine -Worker ([string]$originalPick.name) `
                            -WindowDecision $crossings -Outcome held
                        return $resultBase + @{
                            ok=$false; spend=0.0; chose=$originalPick.name; why=$holdLine; alternatives=$alts
                        }
                    }
                    $pick = $preflightCandidates[0]
                    $policy = $substitution.policy
                    [void]$attemptedProviders.Add([string]$pick.name)
                    $alts = @($preflightCandidates | Select-Object -Skip 1 | ForEach-Object { $_.name })

                    # One-hop only: re-run the same probe+cap preflight on the substitute
                    # before dispatch. If the hop target is also over cap, hold (no chain).
                    $subProvider = Get-FleetProvider -Name ([string]$pick.name) -Path $FleetPath
                    $subCanProbe = ($null -ne $subProvider) -and ($null -ne $subProvider.usage_policy) -and
                        ($subProvider.usage_policy.probe -eq $true) -and ([string]$subProvider.kind -eq 'cli') -and
                        ([string]$subProvider.platform -eq 'codex')
                    if ($subCanProbe) {
                        $subSnapshot = Get-CodexUsageProbe -Worker ([string]$pick.name) -Transport $ProbeTransport `
                            -CachePath $ProbeCachePath -Now $preflightNow -TimeoutSeconds 20 -TtlSeconds 600
                        if ($null -ne $subSnapshot) {
                            $subCapDecision = Get-UsageProbeCapDecision -Provider $subProvider `
                                -Observations @($subSnapshot.observations)
                            if ($subCapDecision.over_cap) {
                                Add-UsageProbeLimitedRows -Worker ([string]$pick.name) -Decision $subCapDecision `
                                    -UsagePath $UsagePath
                                Add-UsagePreflightEvent -Worker ([string]$originalPick.name) -Outcome held `
                                    -WindowDecision $crossings -Substitute ([string]$pick.name) -UsagePath $UsagePath `
                                    -Reason 'soft_cap' -Timestamp $preflightNow.ToString('o')
                                $holdLine = Format-UsagePreflightLine -Worker ([string]$originalPick.name) `
                                    -WindowDecision $crossings -Outcome held -AlsoOverCap ([string]$pick.name)
                                return $resultBase + @{
                                    ok=$false; spend=0.0; chose=$originalPick.name; why=$holdLine; alternatives=$alts
                                }
                            }
                        }
                    }

                    Add-UsagePreflightEvent -Worker ([string]$originalPick.name) -Outcome rerouted `
                        -WindowDecision $crossings -Substitute ([string]$pick.name) -UsagePath $UsagePath `
                        -Reason 'soft_cap' -Timestamp $preflightNow.ToString('o')
                    $hopLine = Format-UsagePreflightLine -Worker ([string]$originalPick.name) `
                        -WindowDecision $crossings -Outcome rerouted -Substitute ([string]$pick.name)
                    $preflightRerouted = $true
                    $resultBase = New-AgenticResultBase -Candidate $pick -Policy $policy -FleetPath $FleetPath
                } else {
                    $preflightReason = if ([string]$pick.usage_preference_reason) { [string]$pick.usage_preference_reason } else { 'under_soft_cap' }
                    Add-UsagePreflightEvent -Worker ([string]$pick.name) -Outcome dispatched `
                        -WindowDecision $evidenceWindow -UsagePath $UsagePath -Reason $preflightReason `
                        -Timestamp $preflightNow.ToString('o')
                }
            }
        }

        $preTree = Get-WorktreeTreeSha -Worktree $Worktree
        $firstAttempt = Invoke-AgenticDispatchAttempt -Candidate $pick -Prompt $prompt -DepthTier $policy.depth_tier `
            -Worktree $Worktree -FleetPath $FleetPath -UsagePath $UsagePath -Dispatcher $Dispatcher
        $res = $firstAttempt.result
        # Capture on success AND failure — a failed attempt's residue is what rework needs.
        Write-TaskBusOutput -RunDir $RunDir -TaskId ([string]$task.id) -Stdout $(if ($null -ne $res) { [string]$res.stdout } else { '' })
        $observation = Get-AgenticUsageObservation -Result $res -Worker ([string]$pick.name) -UsagePath $UsagePath `
            -PromptBytes (Get-Utf8ByteCount -Text $prompt)
        $firstPostTree = Get-WorktreeTreeSha -Worktree $Worktree
        $hadPartialDiff = ($null -ne $preTree) -and ($null -ne $firstPostTree) -and ($preTree -ne $firstPostTree)

        # hard_failover = quota/burst usage hop. context_overflow is NOT a usage
        # lockout (provider stays routable) but still gets one quality_first peer
        # retry with a soft preference for larger declared max_prompt_bytes.
        $isContextOverflow = $observation -and ([string]$observation.classification -eq 'context_overflow')
        $shouldSubstitute = [int]$res.exit_code -ne 0 -and $observation -and
            $FailoverPolicy -eq 'quality_first' -and -not $preflightRerouted -and
            ($observation.hard_failover -or $isContextOverflow)
        if ($shouldSubstitute) {
            # v1.17.0 delta: re-resolve the same authoritative stakes/depth policy
            # before substitute selection. Never reuse a raw pre-policy ladder.
            $substitution = Resolve-AgenticSubstituteCandidates -Capability $cap -OriginalCandidate $pick `
                -AttemptedProviders $attemptedProviders -PolicyArgs $policyArgs -FleetPath $FleetPath `
                -ToolsPath $ToolsPath -UsagePath $UsagePath -RatingsPath $RatingsPath -JournalPath $JournalPath
            $retryPolicy = $substitution.policy
            $retryCandidates = @($substitution.candidates)
            if ($isContextOverflow -and $retryCandidates.Count -gt 0) {
                $retryCandidates = @(Sort-ContextOverflowCandidates -Candidates ([object[]]$retryCandidates) -FleetPath $FleetPath)
            }
            if ($retryCandidates.Count -lt 1) {
                if ($isContextOverflow) {
                    $pb = if ($null -ne $observation.prompt_bytes) { [Nullable[long]][long]$observation.prompt_bytes } else { [Nullable[long]]$null }
                    $fb = if ($null -ne $observation.overflow_floor_bytes) { [long]$observation.overflow_floor_bytes } else { 35000 }
                    $why = Format-ContextOverflowLine -Provider ([string]$pick.name) -PromptBytes $pb -FloorBytes $fb
                } else {
                    $why = "usage failover: $($pick.name) -> no peer available (quality_first; $($observation.classification))"
                }
                return $resultBase + @{ ok=$false; spend=0.0; chose=$pick.name; why=$why; alternatives=$alts }
            }
            if ($null -eq $preTree -or -not (Restore-WorktreeTreeSnapshot -Worktree $Worktree -TreeSha $preTree)) {
                if ($isContextOverflow) {
                    $pb = if ($null -ne $observation.prompt_bytes) { [Nullable[long]][long]$observation.prompt_bytes } else { [Nullable[long]]$null }
                    $fb = if ($null -ne $observation.overflow_floor_bytes) { [long]$observation.overflow_floor_bytes } else { 35000 }
                    $why = (Format-ContextOverflowLine -Provider ([string]$pick.name) -PromptBytes $pb -FloorBytes $fb) +
                        ' (clean worktree restore failed; no retry)'
                } else {
                    $why = "usage failover: $($pick.name) -> no retry (clean worktree restore failed; $($observation.classification))"
                }
                return $resultBase + @{ ok=$false; spend=0.0; chose=$pick.name; why=$why; alternatives=$alts }
            }

            $substitute = $retryCandidates[0]
            [void]$attemptedProviders.Add([string]$substitute.name)
            $retryAlts = @($retryCandidates | Select-Object -Skip 1 | ForEach-Object { $_.name })
            Add-UsageFailoverEvent -OriginalWorker ([string]$pick.name) -Substitute ([string]$substitute.name) `
                -Reason ([string]$observation.classification) -ResetAt ([string]$observation.reset_at) `
                -HadPartialDiff $hadPartialDiff -UsagePath $UsagePath
            if ($isContextOverflow) {
                $hopLine = "context_overflow: $($pick.name) -> $($substitute.name) (prefer larger context)"
            } else {
                $resetText = if ($observation.reset_at) { "reset $($observation.reset_at)" } else { 'reset unknown' }
                $hopLine = "usage failover: $($pick.name) -> $($substitute.name) ($($observation.classification); $resetText)"
            }

            $retryAttempt = Invoke-AgenticDispatchAttempt -Candidate $substitute -Prompt $prompt -DepthTier $retryPolicy.depth_tier `
                -Worktree $Worktree -FleetPath $FleetPath -UsagePath $UsagePath -Dispatcher $Dispatcher
            $res = $retryAttempt.result
            Write-TaskBusOutput -RunDir $RunDir -TaskId ([string]$task.id) -Stdout $(if ($null -ne $res) { [string]$res.stdout } else { '' })
            [void](Get-AgenticUsageObservation -Result $res -Worker ([string]$substitute.name) -UsagePath $UsagePath `
                -PromptBytes (Get-Utf8ByteCount -Text $prompt))
            $pick = $substitute
            $alts = $retryAlts
            $policy = $retryPolicy
            $resultBase = New-AgenticResultBase -Candidate $pick -Policy $policy -FleetPath $FleetPath
            $firstAttempt = $retryAttempt
        }

        $postTree = Get-WorktreeTreeSha -Worktree $Worktree
        $grew = ($null -ne $preTree) -and ($null -ne $postTree) -and ($preTree -ne $postTree)
        # Best-effort per-task incremental diff for the report; never fails the task.
        if ($RunDir -and $grew) {
            try {
                $tasksDir = Join-Path $RunDir 'tasks'
                New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
                $taskDiff = @(& git -C $Worktree diff $preTree $postTree 2>$null) -join "`n"
                Set-Content -LiteralPath (Join-Path $tasksDir "$($task.id).diff") -Value $taskDiff -Encoding utf8NoBOM
            } catch { }
        }
        if ([int]$res.exit_code -ne 0) {
            if ($hopLine) {
                $failureWhy = "$hopLine; substitute exit $($res.exit_code)"
            } elseif ($observation -and [string]$observation.classification -eq 'context_overflow') {
                $pb = if ($null -ne $observation.prompt_bytes) { [Nullable[long]][long]$observation.prompt_bytes } else { [Nullable[long]]$null }
                $fb = if ($null -ne $observation.overflow_floor_bytes) { [long]$observation.overflow_floor_bytes } else { 35000 }
                $failureWhy = Format-ContextOverflowLine -Provider ([string]$pick.name) -PromptBytes $pb -FloorBytes $fb
            } elseif ($firstAttempt.dispatch_error) {
                $failureWhy = "$($pick.name): dispatch error: $($firstAttempt.dispatch_error) ($($observation.classification))"
            } else {
                $failureWhy = "$($pick.name): exit $($res.exit_code) ($($observation.classification))"
            }
            if ($advisoryLines.Count -gt 0) { $failureWhy += '; ' + ($advisoryLines -join '; ') }
            return $resultBase + @{ ok = $false; spend = 0.0; chose = $pick.name; why = $failureWhy; alternatives = $alts }
        }
        if ($grew) {
            $successWhy = if ($hopLine) { "$hopLine; worktree diff grew" } else { "routed $cap -> $($pick.name); worktree diff grew" }
            if ($advisoryLines.Count -gt 0) { $successWhy += '; ' + ($advisoryLines -join '; ') }
            return $resultBase + @{ ok = $true; spend = 0.0; chose = $pick.name; why = $successWhy; alternatives = $alts }
        }
        $noChangeWhy = if ($hopLine) { "$hopLine; no changes" } else { "$($pick.name): no changes" }
        if ($advisoryLines.Count -gt 0) { $noChangeWhy += '; ' + ($advisoryLines -join '; ') }
        return $resultBase + @{ ok = $true; spend = 0.0; chose = $pick.name; why = $noChangeWhy; alternatives = $alts }
    }.GetNewClosure()
}

function Resolve-MaxRework {
    <# Mechanical rework ceiling (spec §4.3). Hard code AbsoluteMaxRework is always
       the outer clamp. Precedence:
         1. explicit Override (hard-clamped)
         2. resolved = min(AbsoluteMaxRework, envOrDefault,
                           taskValue-if-present-else-envOrDefault)
       envOrDefault = BATON_MAX_REWORK if set, else DefaultMaxRework (1).
       Task.max_rework may LOWER below the operator/env ceiling, never raise above
       it — an LLM plan emitting max_rework:50 cannot beat the operator. Always
       clamped to >= 0. #>
    param(
        $Task = $null,
        $Override = $null
    )
    $hard = [int]$script:AbsoluteMaxRework
    if ($null -ne $Override -and "$Override" -ne '') {
        $n = $null
        try { $n = [int]$Override } catch { $n = $null }
        if ($null -eq $n) { $n = [int]$script:DefaultMaxRework }
        if ($n -lt 0) { $n = 0 }
        return [Math]::Min($hard, $n)
    }

    $envOrDefault = [int]$script:DefaultMaxRework
    if ($env:BATON_MAX_REWORK -and "$env:BATON_MAX_REWORK" -ne '') {
        try { $envOrDefault = [int]$env:BATON_MAX_REWORK } catch { $envOrDefault = [int]$script:DefaultMaxRework }
    }
    if ($envOrDefault -lt 0) { $envOrDefault = 0 }

    $taskVal = $null
    if ($null -ne $Task) {
        $has = if ($Task -is [System.Collections.IDictionary]) {
            $Task.Contains('max_rework')
        } else {
            $null -ne $Task.PSObject.Properties['max_rework']
        }
        if ($has -and $null -ne $Task.max_rework -and "$($Task.max_rework)" -ne '') {
            try { $taskVal = [int]$Task.max_rework } catch { $taskVal = $null }
        }
    }
    $taskOrEnv = if ($null -ne $taskVal) { $taskVal } else { $envOrDefault }
    if ($taskOrEnv -lt 0) { $taskOrEnv = 0 }
    return [Math]::Min($hard, [Math]::Min($envOrDefault, $taskOrEnv))
}

function Normalize-ReworkEvidenceText {
    <# Normalize evidence for the identical-findings halt. Collapses whitespace,
       then masks volatile tokens that otherwise make consecutive failures look
       distinct: ISO-8601/RFC timestamps, GUIDs, hex strings >= 8 chars, and
       absolute paths under temp/run dirs.
       Residual risk: arbitrary volatile output (counters, nonces outside these
       patterns) can still defeat the identical-evidence check; AbsoluteMaxRework
       hard cap is the real backstop. #>
    param([AllowEmptyString()][AllowNull()][string]$Text = '')
    if ($null -eq $Text) { return '' }
    $t = [string]$Text
    $t = $t -replace "`r`n", "`n" -replace "`r", "`n"
    $t = $t -replace '[ \t]+', ' '
    $t = $t -replace ' *\n *', "`n"

    # Absolute paths under temp / run dirs -> fixed placeholder (before hex so
    # path segments with hex chars don't get partially rewritten first).
    $tempRoots = [System.Collections.Generic.List[string]]::new()
    foreach ($cand in @(
        [System.IO.Path]::GetTempPath(),
        $env:TEMP, $env:TMP, $env:TMPDIR,
        $env:BATON_HOME
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$cand)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath([string]$cand).TrimEnd('\', '/')
            if ($full -and -not ($tempRoots -contains $full)) { [void]$tempRoots.Add($full) }
        } catch { }
    }
    foreach ($root in $tempRoots) {
        $esc = [regex]::Escape($root) -replace '/', '[\\/]' -replace '\\\\', '[\\/]'
        # Also accept either slash style after the root.
        $t = [regex]::Replace($t, "(?i)$esc[\\/][^\s`"'<>|]+", '<TEMP_PATH>')
    }
    # Common temp path shapes not covered by env (portable fixtures / cross-box).
    $t = [regex]::Replace($t,
        '(?i)(?:[A-Z]:[\\/](?:Users[\\/][^\\/\s]+[\\/]AppData[\\/]Local[\\/]Temp|Windows[\\/]Temp)|/tmp|/var/tmp)[\\/][^\s`"''<>|]+',
        '<TEMP_PATH>')

    # ISO-8601 / RFC-3339 timestamps (with optional fractional seconds + TZ).
    $t = [regex]::Replace($t,
        '\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?',
        '<TIMESTAMP>')
    # RFC-1123-ish date headers (e.g. "Mon, 24 Jul 2026 12:34:56 GMT").
    $t = [regex]::Replace($t,
        '(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2}(?: GMT| UTC)?',
        '<TIMESTAMP>')

    # GUIDs (before bare hex so the full GUID collapses as one token).
    $t = [regex]::Replace($t,
        '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
        '<GUID>')

    # Hex strings >= 8 chars (git shas, content hashes in check output).
    $t = [regex]::Replace($t, '(?i)\b[0-9a-f]{8,}\b', '<HEX>')

    return $t.Trim()
}

function Build-ReworkEvidenceText {
    <# Engine invents nothing: repackage check-output excerpt + the failing task's
       bus residue (Get-TaskBusInputBlock semantics for size caps / missing placeholder).
       Used as the rework task description. #>
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][hashtable]$Verification,
        [string]$RunDir = '',
        [int]$CheckExcerptMaxBytes = 4096
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    $fail = [string]$Verification.failure_category
    if ($fail) { [void]$parts.Add("Failure: $fail") }

    $checkOut = ''
    $op = [string]$Verification.output_path
    if ($op -and (Test-Path -LiteralPath $op)) {
        try {
            $raw = Get-Content -LiteralPath $op -Raw -ErrorAction Stop
            if ($null -eq $raw) { $raw = '' }
            $checkOut = Limit-Utf8TextWithMarker -Text $raw -MaxBytes $CheckExcerptMaxBytes
        } catch { $checkOut = '' }
    }
    [void]$parts.Add('Check output:')
    [void]$parts.Add($(if ($checkOut) { $checkOut } else { '(empty)' }))

    $tid = [string]$Task.id
    if ($RunDir -and $tid) {
        # Same caps / missing placeholder as depends_on injection — treat the failed
        # task's own output.md as the residue the rework must see.
        $busBlock = Get-TaskBusInputBlock -RunDir $RunDir -DependsOn @($tid)
        if ([string]::IsNullOrWhiteSpace($busBlock)) {
            [void]$parts.Add("## Inputs from $tid`n(no output was produced)")
        } else {
            [void]$parts.Add($busBlock)
        }
    }
    return ($parts -join "`n")
}

function Write-ReworkEvidenceFile {
    <# Persist triggering evidence under tasks/<id>/rework-evidence-<N>.md so the
       decisions.jsonl row can name a path, not content. Returns the absolute path. #>
    param(
        [Parameter(Mandatory)][string]$TaskDir,
        [Parameter(Mandatory)][int]$Cycle,
        [AllowEmptyString()][string]$Text = ''
    )
    New-Item -ItemType Directory -Force -Path $TaskDir | Out-Null
    $path = Join-Path $TaskDir "rework-evidence-$Cycle.md"
    Set-Content -LiteralPath $path -Value $Text -Encoding utf8NoBOM
    return $path
}

function New-ReworkTaskFromEvidence {
    <# Synthesize ONE rework task: desc = verbatim evidence; allowed_paths,
       verify_profile, stakes (and every other property) inherited from the failing
       task. Engine invents nothing beyond the packaging. #>
    param(
        [Parameter(Mandatory)]$SourceTask,
        [Parameter(Mandatory)][AllowEmptyString()][string]$EvidenceText
    )
    $t = $SourceTask.PSObject.Copy()
    $t.desc = $EvidenceText
    return $t
}

function Test-ReworkableFailure {
    <# Check-fail family only. Scope/oracle violations stay fail-closed (no rework). #>
    param([AllowEmptyString()][string]$FailureCategory = '')
    return ([string]$FailureCategory -in $script:ReworkableFailureCategories)
}

function Format-VerifyEvidencePrompt {
    <# Bounded evidence brief (legacy 965-byte path, still used by tests / inline
       instruments). Slice 2 rework packaging prefers Build-ReworkEvidenceText
       (bus-aware, evidence-only). Original task + failure category + capped excerpt
       + fix-in-place instruction, whole prompt <=965 UTF-8 bytes. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskDesc,
        [Parameter(Mandatory)][hashtable]$Verification,
        [string]$OutputPath = '',
        [int]$MaxBytes = 900
    )
    $enc = [System.Text.Encoding]::UTF8
    # Budget the desc first: it must not itself consume the whole ceiling. Reserve room
    # for the boilerplate + failure line + a minimum excerpt floor.
    $boiler = @"
{0}

--- Your previous attempt did not pass verification. Fix the EXISTING work; do not
restart from scratch and do not broaden the change beyond the task's scope. ---
Failure: {1}
Check output:
{2}
"@
    $fail = [string]$Verification.failure_category
    # Bytes the template consumes with empty desc/excerpt — measure so the two variable
    # parts share exactly the remaining budget.
    $fixedBytes = $enc.GetByteCount(($boiler -f '', $fail, ''))
    $descCap = [Math]::Max(120, [int](($MaxBytes - $fixedBytes) * 0.55))
    $desc = $TaskDesc
    while ($enc.GetByteCount($desc) -gt $descCap -and $desc.Length -gt 0) {
        $desc = $desc.Substring(0, [Math]::Max(0, $desc.Length - 16))
    }
    $excerptCap = $MaxBytes - $fixedBytes - $enc.GetByteCount($desc)
    if ($excerptCap -lt 0) { $excerptCap = 0 }
    $excerpt = ''
    if ($OutputPath -and (Test-Path -LiteralPath $OutputPath) -and $excerptCap -gt 0) {
        $raw = Get-Content -LiteralPath $OutputPath -Raw
        if ($null -eq $raw) { $raw = '' }
        while ($enc.GetByteCount($raw) -gt $excerptCap -and $raw.Length -gt 0) {
            $raw = $raw.Substring(0, [Math]::Max(0, $raw.Length - 16))
        }
        $excerpt = $raw
    }
    $prompt = $boiler -f $desc, $fail, $excerpt
    # Final safety clamp: if multibyte rounding pushed us over, trim the tail to fit.
    while ($enc.GetByteCount($prompt) -gt $MaxBytes -and $prompt.Length -gt 0) {
        $prompt = $prompt.Substring(0, [Math]::Max(0, $prompt.Length - 8))
    }
    # Seam 2 (retry/evidence): same task-output instruction as New-AgenticSpawner.
    # Reserve the instruction inside MaxBytes so VS7's 965-byte ceiling still holds.
    $instr = Get-TaskOutputInstructionBlock
    $instrBytes = $enc.GetByteCount("`n`n$instr")
    $bodyBudget = [Math]::Max(0, $MaxBytes - $instrBytes)
    while ($enc.GetByteCount($prompt) -gt $bodyBudget -and $prompt.Length -gt 0) {
        $prompt = $prompt.Substring(0, [Math]::Max(0, $prompt.Length - 8))
    }
    $prompt = $prompt.TrimEnd() + "`n`n" + $instr
    while ($enc.GetByteCount($prompt) -gt $MaxBytes -and $prompt.Length -gt 0) {
        $prompt = $prompt.Substring(0, [Math]::Max(0, $prompt.Length - 8))
    }
    return $prompt
}

function Add-VerifyAttemptRow {
    <# Append one attempt row to <RunTaskDir>/attempts.jsonl (codex-ringer §10). One
       compact JSON object per line; utf8NoBOM append. #>
    param(
        [Parameter(Mandatory)][string]$RunTaskDir,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][hashtable]$Row
    )
    New-Item -ItemType Directory -Force -Path $RunTaskDir | Out-Null
    $rec = [ordered]@{
        attempt          = $Attempt
        worker           = [string]$Row.worker
        worker_ok        = [bool]$Row.worker_ok
        diff_grew        = [bool]$Row.diff_grew
        verdict          = [string]$Row.verdict
        grade            = [string]$Row.grade
        failure_category = [string]$Row.failure_category
        first_try        = ($Attempt -eq 1)
        duration_ms      = [int]$Row.duration_ms
    }
    Add-Content -LiteralPath (Join-Path $RunTaskDir 'attempts.jsonl') -Value ($rec | ConvertTo-Json -Compress -Depth 6) -Encoding utf8NoBOM
}

function New-VerifyingSpawner {
    <# Wrap an inner agentic spawner with the d082 verification sub-lifecycle + the
       engine-owned rework loop (#128 slice 2). Per task: no verify_profile / no frozen
       contract -> delegate + mark unverified. Otherwise: freeze pre-hashes once before
       attempt 1, run the inner attempt, compute the task diff, run the frozen contract,
       apply A5 non-empty-diff. On a check-fail family verdict the engine synthesizes
       up to max_rework (default 1) evidence-only rework tasks in the SAME worktree —
       this SUBSUMES the old single evidence-informed retry (one loop, one counter, one
       journal vocabulary). Scope/oracle violations stay fail-closed with NO rework.
       Identical normalized failure evidence across consecutive cycles halts without
       re-sending. Writes attempts.jsonl + verification.json (+ rework-evidence-N.md). #>
    param(
        [Parameter(Mandatory)][scriptblock]$InnerSpawner,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$FrozenContracts,
        $MaxRework = $null
    )
    $maxReworkOverride = $MaxRework
    return {
        param($task)
        $prof = [string]$task.verify_profile
        if (-not $prof -or -not $FrozenContracts.ContainsKey([string]$task.id)) {
            $r = & $InnerSpawner $task
            $r.unverified = $true
            return $r
        }
        $contract = $FrozenContracts[[string]$task.id].contract
        $taskDir = Join-Path $RunDir "tasks/$($task.id)"
        New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
        $allowed = @($task.allowed_paths | Where-Object { $_ } | ForEach-Object { [string]$_ })

        # A5 baseline (review I1): freeze the PRE-TASK state ONCE, before attempt 1, and
        # judge EVERY attempt (including rework) against it — codex-ringer §7 / design A5.
        $protPre0   = Get-VerifyPathHashes -WorktreeRoot $Worktree -Paths @($contract.protected_paths)
        $expectPre0 = Get-VerifyPathHashes -WorktreeRoot $Worktree -Paths @($contract.expect_files)
        $taskStartTree = Get-WorktreeTreeSha -Worktree $Worktree

        $runAttempt = {
            param($atask, $attemptNo)
            $ir = & $InnerSpawner $atask
            $postTree = Get-WorktreeTreeSha -Worktree $Worktree
            # Cumulative vs the frozen task-start tree — never vs the previous attempt.
            $grew = ($null -ne $taskStartTree) -and ($null -ne $postTree) -and ($taskStartTree -ne $postTree)
            $diffFiles = @()
            if ($grew) { $diffFiles = @(& git -C $Worktree diff --name-only $taskStartTree $postTree 2>$null | Where-Object { $_ }) }
            # Test hook: a hermetic override of the real runner (BATON_VERIFY_TEST_HOOK
            # points at a file defining Invoke-TestVerify -Task -Attempt -Grew).
            if ($env:BATON_VERIFY_TEST_HOOK -and (Test-Path -LiteralPath $env:BATON_VERIFY_TEST_HOOK)) {
                . $env:BATON_VERIFY_TEST_HOOK
                $v = Invoke-TestVerify -Task $atask -Attempt $attemptNo -Grew $grew
            } else {
                $v = Invoke-VerificationContract -Contract $contract -WorktreeRoot $Worktree -RunTaskDir $taskDir `
                        -DiffFiles $diffFiles -AllowedPaths $allowed -ExpectPreHashes $expectPre0 -ProtectedPreHashes $protPre0
            }
            # A5 (adjudication): an edit task's PASS also requires a non-empty task diff
            # vs the pre-task baseline. A "passing" check over a tree unchanged since task
            # start is demoted to a rework-eligible no-change failure (closes the V1
            # zero-change loophole on EVERY attempt).
            if ([string]$v.verdict -eq 'pass' -and -not $grew) {
                $v.verdict = 'fail'; $v.ok = $false; $v.grade = 'invalid'; $v.failure_category = 'no-change'
            }
            return @{ v = $v; inner = $ir; grew = $grew }
        }
        # NOTE: no .GetNewClosure() here — a nested GetNewClosure does not re-capture the
        # enclosing spawner-closure's variables ($Worktree/$InnerSpawner/$taskStartTree),
        # so it would run them empty. $runAttempt is invoked in this same scope, so plain
        # dynamic scoping resolves the pre-task baseline + $contract/$taskDir/$allowed from
        # the live parent.

        $a1 = & $runAttempt $task 1
        Add-VerifyAttemptRow -RunTaskDir $taskDir -Attempt 1 -Row @{
            worker = [string]$a1.inner.chose; worker_ok = [bool]$a1.inner.ok; diff_grew = $a1.grew
            verdict = $a1.v.verdict; grade = $a1.v.grade; failure_category = $a1.v.failure_category; duration_ms = $a1.v.duration_ms
        }
        $final = $a1
        $firstFail = [string]$a1.v.failure_category
        # Spend accrues across ALL attempts (review M2) — rework labor must not drop
        # attempt 1's spend once realized cost lands via the Get-RunCost seam.
        $totalSpend = [double]$a1.inner.spend

        # Engine-owned rework loop (slice 2): SUBSUMES the old single evidence-informed
        # retry. Counter is mechanical (Resolve-MaxRework); never prompt text.
        # Precedence: pass -> done. scope/oracle or non-reworkable -> fail-closed, NO rework.
        # check-fail family -> up to max_rework evidence-only rework cycles in SAME worktree.
        $maxRework = Resolve-MaxRework -Task $task -Override $maxReworkOverride
        $reworkCycles = 0
        $reworks = [System.Collections.Generic.List[object]]::new()
        $prevEvidenceNorm = $null
        $haltReason = ''

        while (
            [string]$final.v.verdict -ne 'pass' -and
            (Test-ReworkableFailure -FailureCategory ([string]$final.v.failure_category)) -and
            $reworkCycles -lt $maxRework
        ) {
            $evidenceText = Build-ReworkEvidenceText -Task $task -Verification $final.v -RunDir $RunDir
            $evidenceNorm = Normalize-ReworkEvidenceText -Text $evidenceText

            # Identical-findings halt: never re-send the same feedback. Applies when a
            # prior cycle already failed — compare this failure's evidence to the evidence
            # that triggered the previous rework (i.e. the previous failure).
            if ($reworkCycles -ge 1 -and $null -ne $prevEvidenceNorm -and $evidenceNorm -eq $prevEvidenceNorm) {
                $haltReason = 'identical-evidence'
                break
            }

            $reworkCycles++
            $evidencePath = Write-ReworkEvidenceFile -TaskDir $taskDir -Cycle $reworkCycles -Text $evidenceText
            $prevEvidenceNorm = $evidenceNorm
            $reworkTask = New-ReworkTaskFromEvidence -SourceTask $task -EvidenceText $evidenceText
            $attemptNo = $reworkCycles + 1
            $aN = & $runAttempt $reworkTask $attemptNo
            Add-VerifyAttemptRow -RunTaskDir $taskDir -Attempt $attemptNo -Row @{
                worker = [string]$aN.inner.chose; worker_ok = [bool]$aN.inner.ok; diff_grew = $aN.grew
                verdict = $aN.v.verdict; grade = $aN.v.grade; failure_category = $aN.v.failure_category; duration_ms = $aN.v.duration_ms
            }
            $final = $aN
            $totalSpend += [double]$aN.inner.spend
            $outcome = if ([string]$aN.v.verdict -eq 'pass') { 'passed' } else { 'failed' }
            [void]$reworks.Add([ordered]@{
                cycle            = $reworkCycles
                evidence_path    = $evidencePath
                outcome          = $outcome
                failure_category = [string]$aN.v.failure_category
                attempt          = $attemptNo
            })
            if ($outcome -eq 'passed') { break }
        }

        # Stamp haltReason from the actual exit cause — not "max_rework" for every
        # post-cycle non-pass. Non-reworkable category (e.g. scope-violation after a
        # rework attempt) uses the category name; ceiling exhaustion uses max_rework;
        # identical-evidence is already set inside the loop.
        if ([string]$final.v.verdict -ne 'pass' -and -not $haltReason) {
            $finalCat = [string]$final.v.failure_category
            if ($reworkCycles -gt 0 -and -not (Test-ReworkableFailure -FailureCategory $finalCat)) {
                $haltReason = if ($finalCat) { $finalCat } else { 'non-reworkable' }
            } elseif (
                $reworkCycles -ge $maxRework -and
                $maxRework -gt 0 -and
                (Test-ReworkableFailure -FailureCategory $finalCat)
            ) {
                $haltReason = 'max_rework'
            }
        }

        $v = $final.v
        $retried = ($reworkCycles -gt 0)  # compat alias: rework cycle(s) attempted
        $verObj = @{
            verdict = [string]$v.verdict; grade = [string]$v.grade
            failure_category = [string]$v.failure_category; first_failure_category = $firstFail
            proves = [string]$v.proves; output_path = [string]$v.output_path
            retried = $retried
            rework_cycles = $reworkCycles
            max_rework = $maxRework
            rework_halt_reason = $haltReason
            reworks = @($reworks)
        }
        ConvertTo-Json -InputObject $verObj -Depth 8 | Set-Content -LiteralPath (Join-Path $taskDir 'verification.json') -Encoding utf8NoBOM

        $passed = ([string]$v.verdict -eq 'pass')
        $why = if ($passed) { "$($final.inner.why); verified (grade $($v.grade))" }
               else { "$($final.inner.why); verification $($v.verdict): $($v.failure_category)" }
        if ($haltReason -and -not $passed) { $why += "; rework halted ($haltReason)" }
        $result = @{
            ok = $passed; spend = [double]$totalSpend; chose = [string]$final.inner.chose
            why = $why; alternatives = @($final.inner.alternatives)
            verification = $verObj; unverified = $false
        }
        foreach ($field in @('stakes','stakes_basis','depth_tier','depth_applied','selection_mode','tier_cap','selected_cost_tier')) {
            $hasField = if ($final.inner -is [System.Collections.IDictionary]) {
                $final.inner.Contains($field)
            } else {
                $null -ne $final.inner.PSObject.Properties[$field]
            }
            if ($hasField) { $result[$field] = $final.inner.$field }
        }
        return $result
    }.GetNewClosure()
}
