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
. "$PSScriptRoot/routing-observe-lib.ps1"   # #159 write-on-observe outcome ratings
. "$PSScriptRoot/diff-apply-lib.ps1"   # d103 parse/apply/context for the diff-apply dispatch branch

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

function Test-ProviderDiffApply {
    <# Diff-apply eligibility (d103, closes #168): a provider reachable only over a
       text transport (kind http / stdio-json) has no filesystem harness, but it can
       still take an edit task when Baton does the hands — read the files in, take
       SEARCH/REPLACE blocks back, apply them to the worktree. The opt-in is explicit
       and required: `diff_apply: true` on the fleet row. Absent or false -> $false.
       A `kind: cli` provider is never a diff-apply worker — it already has hands.
       Pure predicate over a provider object: deliberately depends on nothing in
       diff-apply-lib.ps1, so eligibility can be asked long before any edit is applied.
       Accepts a fleet provider hashtable or a Select-Capability candidate object. #>
    param([Parameter(Mandatory)]$Provider)
    if ($Provider.diff_apply -ne $true) { return $false }
    return ([string]$Provider.kind -in @('http', 'stdio-json'))
}

function Test-ProviderEditCapable {
    <# The question every edit call site actually asks: may this provider take an edit
       task at all? True when it brings its own filesystem harness
       (Test-ProviderAgentic) OR when Baton can apply its diffs for it
       (Test-ProviderDiffApply). Test-ProviderAgentic keeps the d091 transport veto
       exactly as it was — diff-apply is a SEPARATE capability, not a relaxation of
       that veto: an `agentic: true` marker still cannot grant edit powers to a text
       transport, only an explicit `diff_apply: true` can. #>
    param([Parameter(Mandatory)]$Provider)
    return ((Test-ProviderAgentic -Provider $Provider) -or (Test-ProviderDiffApply -Provider $Provider))
}

function Resolve-CandidateEditMode {
    <# How — if at all — a ROUTED CANDIDATE may take an edit task:
       'agentic'    it brings its own filesystem harness (d078),
       'diff-apply' Baton reads the files and applies its SEARCH/REPLACE blocks (d103),
       'none'       it may not take edit work.

       Why this exists instead of calling Test-ProviderEditCapable on the candidate:
       Select-Capability's candidate projection carries `agentic` but NOT
       `diff_apply`, so a pure predicate over the candidate alone would filter every
       diff-apply provider out of the pool before it could ever be dispatched. Prefer
       what the candidate carries; fall back to a fleet.yaml re-read for the missing
       opt-in — the same prefer-candidate-then-reread shape
       Sort-ContextOverflowCandidates uses for max_prompt_bytes.

       The d091 transport veto is untouched: 'agentic' is still decided solely by
       Test-ProviderAgentic, so an `agentic: true` marker on a text transport still
       grants nothing. Only an explicit `diff_apply: true` reaches 'diff-apply'. #>
    param(
        [Parameter(Mandatory)]$Candidate,
        [string]$FleetPath = ''
    )
    if (Test-ProviderAgentic -Provider $Candidate) { return 'agentic' }
    if (Test-ProviderDiffApply -Provider $Candidate) { return 'diff-apply' }
    if (-not [string]::IsNullOrWhiteSpace($FleetPath)) {
        $row = $null
        try { $row = Get-FleetProvider -Name ([string]$Candidate.name) -Path $FleetPath } catch { $row = $null }
        if ($null -ne $row -and (Test-ProviderDiffApply -Provider $row)) { return 'diff-apply' }
    }
    return 'none'
}

function Get-CapabilityCostTierFloor {
    <# Cheapest cost_tier among enabled fleet providers that claim $Capability.
       For code-gen/code-transform, only edit-eligible providers count
       (Test-ProviderEditCapable — agentic harness OR diff-apply opt-in; d103/#168
       is what lets a local diff-apply provider put a real floor under code-gen
       instead of the whole capability reading UNAVAILABLE below the paid tier).
       Also applies Select-Capability context floors
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
                if (-not (Test-ProviderEditCapable -Provider $prov)) { continue }
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

function Get-EditPoolExclusions {
    <# Per-provider audit of an empty edit pool (#124). Walks every fleet provider
       and names why each one cannot take this dispatch, split into 'static'
       exclusions (config-shaped: disabled / no capability claim / not
       edit-eligible / context floor / tier cap) and 'usage' exclusions (the
       provider passes every static check but is out on availability: lockout,
       cooldown, conserve-mode limited). Callers use the split to tell 'the
       roster cannot do this' (#127 stakes/tier remedy) from 'everyone who could
       is out right now' (labor-unavailable). Mirrors Select-Capability's
       route-around rules: hard states always exclude; 'limited' excludes only
       under conserve mode. Fail-soft: unreadable fleet -> @(). #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$TierCap,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl'),
        [datetime]$Now = [datetime]::UtcNow
    )
    try {
        if ([string]::IsNullOrWhiteSpace($FleetPath) -or -not (Test-Path -LiteralPath $FleetPath)) {
            return @()
        }
        $providers = @(Read-Fleet -Path $FleetPath)
        $generalCaps = @(Get-GeneralCapabilities -FleetPath $FleetPath)
        $capFloors = @{}
        if (Get-Command Get-CapabilityFloors -ErrorAction SilentlyContinue) {
            $capFloors = Get-CapabilityFloors -FleetPath $FleetPath
        }
        $usageRows = @()
        $conserve = $false
        if (Get-Command Get-WorkerState -ErrorAction SilentlyContinue) {
            $usageRows = @(Read-UsageJournal -Path $UsagePath)
            if ($usageRows.Count -gt 0) { $conserve = Get-ConserveMode -Rows $usageRows }
        }
        $rows = [System.Collections.ArrayList]@()
        foreach ($prov in $providers) {
            $name = [string]$prov.name
            if ($prov.enabled -ne $true) {
                [void]$rows.Add([ordered]@{ name = $name; stage = 'static'; reason = 'disabled'; reset_at = $null; eta = $null })
                continue
            }
            $claims = $prov.capabilities
            $claimsCap = if ($null -ne $claims) { @($claims) -contains $Capability }
                         else { $generalCaps -contains $Capability }
            if (-not $claimsCap) {
                [void]$rows.Add([ordered]@{ name = $name; stage = 'static'; reason = "does not claim $Capability"; reset_at = $null; eta = $null })
                continue
            }
            if (-not (Test-ProviderEditCapable -Provider $prov)) {
                # Name the actionable remedy: a text-transport provider is one config
                # line (diff_apply: true) away from eligible, so say so instead of the
                # generic verdict an operator can do nothing about.
                $editReason = if ([string]$prov.kind -in @('http', 'stdio-json')) {
                    'not edit-eligible (no diff_apply opt-in)'
                } else { 'not edit-eligible' }
                [void]$rows.Add([ordered]@{ name = $name; stage = 'static'; reason = $editReason; reset_at = $null; eta = $null })
                continue
            }
            if ($capFloors.ContainsKey($Capability) -and $prov.context -and
                ([int]$prov.context -lt $capFloors[$Capability])) {
                [void]$rows.Add([ordered]@{ name = $name; stage = 'static'; reason = ("context below {0} floor" -f $capFloors[$Capability]); reset_at = $null; eta = $null })
                continue
            }
            $tierName = [string]$prov.cost_tier
            if ((Get-CostTierRank $tierName) -gt (Get-CostTierRank $TierCap)) {
                [void]$rows.Add([ordered]@{ name = $name; stage = 'static'; reason = "cost_tier $tierName above cap $TierCap"; reset_at = $null; eta = $null })
                continue
            }
            # Every static check passed — only availability can have excluded it.
            if ($usageRows.Count -gt 0) {
                $st = Get-WorkerState -Worker $name -Rows $usageRows -Now $Now
                if ([string]$st.state -in @('exhausted', 'cooling_down', 'waiting_for_reset')) {
                    [void]$rows.Add([ordered]@{ name = $name; stage = 'usage'; reason = [string]$st.state; reset_at = $st.reset_at; eta = $st.eta_human })
                    continue
                }
                if ([string]$st.state -eq 'limited' -and $conserve) {
                    [void]$rows.Add([ordered]@{ name = $name; stage = 'usage'; reason = 'limited (conserve mode)'; reset_at = $st.reset_at; eta = $st.eta_human })
                    continue
                }
            }
            # Nothing this audit models excluded it — selection should have kept it.
            # Say so honestly instead of inventing a cause.
            [void]$rows.Add([ordered]@{ name = $name; stage = 'static'; reason = 'eligible by this audit (exclusion cause outside model)'; reset_at = $null; eta = $null })
        }
        return ([object[]]$rows.ToArray())
    } catch { return @() }
}

function Format-ZeroCandidateWhy {
    <# Human-readable failure for the New-AgenticSpawner zero-candidate seam (#127).
       Message only; does not change routing. Cause-aware (#124): when the
       exclusion audit shows availability ('usage') exclusions, the pool COULD do
       the work but everyone is out — say that, with per-provider resets, instead
       of the stakes/tier remedy (which would mislead: raising stakes cannot fix
       a lockout). Without usage exclusions the #127 stakes/tier message stands. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$TierCap,
        [Parameter(Mandatory)][string]$Stakes,
        [Parameter(Mandatory)][string]$Floor,
        [object[]]$Exclusions = @()
    )
    $usageOut = @($Exclusions | Where-Object { [string]$_.stage -eq 'usage' })
    if ($usageOut.Count -gt 0) {
        $detail = ($usageOut | ForEach-Object {
            $bit = "$($_.name): $($_.reason)"
            if ($_.eta) { $bit += " (resets $($_.eta))" }
            elseif ($_.reset_at) { $bit += " (reset_at $($_.reset_at))" }
            $bit
        }) -join '; '
        $msg = "capability ${Capability}: labor unavailable — every provider that could take this edit is out: ${detail}. Remedies: wait for the reset, clear a stale lockout (Add-UsageEvent -Kind clear), or enable another edit-eligible provider."
        # Mixed pool (Grok review medium): when tier-capped providers ALSO exist, the
        # #127 stakes remedy is still live — dropping it entirely would re-mislead.
        $tierExcluded = @($Exclusions | Where-Object { [string]$_.stage -eq 'static' -and [string]$_.reason -match 'above cap' })
        if ($tierExcluded.Count -gt 0) {
            $names = ($tierExcluded | ForEach-Object { [string]$_.name }) -join ', '
            $msg += " Note: ${names} sat above the tier cap (${TierCap}) — raising task est_cost_tier or re-running with higher --stakes could also widen the pool."
        }
        return $msg
    }
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

function Publish-RunBranch {
    <# Commit the staged run tree and publish the exact run branch to origin.
       This is the terminal durability step for retained execute work (#157). #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunDir
    )

    $remoteRef = "refs/heads/$Branch"
    $archive = [ordered]@{
        schema = 1
        status = 'failed'
        branch = $Branch
        base_sha = $BaseSha
        commit_sha = ''
        committed = $false
        pushed = $false
        remote = 'origin'
        remote_ref = $remoteRef
        reason = ''
    }

    try {
        if (-not $Branch.StartsWith('baton/run-', [StringComparison]::Ordinal) -or
            $Branch.Length -le 'baton/run-'.Length) {
            throw "expected branch must match baton/run-*: $Branch"
        }
        $currentBranch = ([string](& git -C $Worktree branch --show-current 2>$null)).Trim()
        if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $Branch) {
            throw "expected branch $Branch is not checked out (found $currentBranch)"
        }

        & git -C $Worktree add -A 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git add failed while archiving run branch' }

        & git -C $Worktree diff --cached --quiet HEAD 2>$null
        $diffExit = $LASTEXITCODE
        if ($diffExit -eq 1) {
            $runId = $Branch.Substring('baton/run-'.Length)
            $message = "chore(baton-run): archive unreviewed run $runId"
            $out = & git -C $Worktree commit -q -m $message 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git commit failed while archiving run branch: $(@($out) -join ' ')" }
            $archive.committed = $true
        } elseif ($diffExit -ne 0) {
            throw 'git diff failed while archiving run branch'
        }

        $localTip = ([string](& git -C $Worktree rev-parse HEAD 2>$null)).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($localTip)) {
            throw 'could not resolve archived run branch tip'
        }
        $archive.commit_sha = $localTip

        if ($localTip -eq $BaseSha) {
            $archive.status = 'skipped-no-changes'
            $archive.reason = 'no tree changes or commits differ from the base'
        } else {
            $out = & git -C $Worktree push origin "HEAD:$remoteRef" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git push to origin failed while archiving run branch: $(@($out) -join ' ')" }

            $remoteLine = [string](& git -C $RepoPath ls-remote --heads origin $remoteRef 2>$null)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteLine)) {
                throw 'could not verify archived run branch on origin'
            }
            $remoteTip = ($remoteLine.Trim() -split '\s+')[0]
            if ($remoteTip -ne $localTip) { throw 'archived run branch tip does not match origin' }

            $archive.status = 'pushed'
            $archive.pushed = $true
            $archive.reason = 'run branch archived to origin'
        }
    } catch {
        $archive.status = 'failed'
        $archive.reason = $_.Exception.Message
    }

    New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
    $archive | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $RunDir 'archive.json') -Encoding utf8NoBOM
    return $archive
}

function Format-RunArchiveSection {
    param(
        [Parameter(Mandatory)]$Archive,
        [Parameter(Mandatory)][string]$Worktree
    )
    if ($Archive.status -eq 'pushed') {
        return "## Durability`n`nArchived unreviewed run branch ``$($Archive.branch)`` at ``$($Archive.commit_sha)`` to ``origin``. Baton did not merge it."
    }
    if ($Archive.status -eq 'skipped-no-changes') {
        return '## Durability' + "`n`nNo tree changes or commits differed from the base; no archive commit or push was needed."
    }
    return "## Durability`n`nARCHIVE FAILED: $($Archive.reason)`n`nLocal recovery remains at ``$Worktree`` on ``$($Archive.branch)``."
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

function Invoke-DiffApplyAttempt {
    <# One dispatch to a provider that has no filesystem harness (d103, closes #168):
       Baton reads the in-scope files, hands them to the model as text, takes
       SEARCH/REPLACE blocks back, and applies them to the worktree itself.

       Same return shape as Invoke-AgenticDispatchAttempt —
       @{ result = @{ stdout; stderr; exit_code; duration_s }; dispatch_error } — plus
       `prompt_sent`, the prompt that was ACTUALLY dispatched. The caller must measure
       that one: the agentic prompt it also built was never sent, and feeding its size
       into context-overflow detection would mis-decide the failover to a
       larger-context peer.

       This function produces a diff; it never judges one. The scope oracle and the
       frozen verification contract downstream remain the sole authorities on whether
       the resulting work is acceptable. #>
    param(
        [Parameter(Mandatory)]$Candidate,
        [AllowEmptyString()][AllowNull()][string]$TaskDesc = '',
        [AllowEmptyString()][AllowNull()][string]$InputBlock = '',
        [AllowNull()][string[]]$AllowedPaths = @(),
        [Parameter(Mandatory)][string]$DepthTier,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$FleetPath,
        [Parameter(Mandatory)][string]$UsagePath,
        [AllowEmptyString()][AllowNull()][string]$RunDir = '',
        [AllowEmptyString()][AllowNull()][string]$TaskId = '',
        [string]$ObservationPath = '',
        [scriptblock]$Dispatcher
    )
    $name = [string]$Candidate.name
    $providerRow = $null
    try { $providerRow = Get-FleetProvider -Name $name -Path $FleetPath } catch { $providerRow = $null }
    $limitsSource = if ($null -ne $providerRow) { $providerRow } else { $Candidate }
    $limits = Get-DiffApplyLimits -Provider $limitsSource

    # Telemetry row (d103 Task 4). Every field is filled in as it becomes known and
    # written exactly once, on whichever path this attempt exits by. Fail-soft:
    # Write-DiffApplyObservation swallows its own faults and can never fail a task.
    $obs = [ordered]@{
        run_id         = $(if ($RunDir) { Split-Path -Leaf $RunDir } else { '' })
        task_id        = [string]$TaskId
        provider       = $name
        model_version  = $(if ($null -ne $providerRow) { [string]$providerRow.model_default } else { '' })
        context_bytes  = 0
        file_count     = 0
        blocks_emitted = 0
        blocks_applied = 0
        parse_result   = ''
        apply_result   = ''
        verdict        = ''
    }

    $ctx = Get-DiffApplyContext -Worktree $Worktree -AllowedPaths $AllowedPaths -Limits $limits
    $obs.context_bytes = [long]$ctx.context_bytes
    $obs.file_count = [int]$ctx.file_count
    if (-not $ctx.ok) {
        # Too big to send: the model never sees this task. The reason string carries
        # the literal 'diff-apply envelope', which Resolve-OutcomeRatingValue matches
        # to skip the capability rating — size is not evidence about model quality.
        $obs.apply_result = 'envelope-exceeded'
        $obs.verdict = 'fail'
        [void](Write-DiffApplyObservation -Row $obs -Path $ObservationPath)
        return @{
            result = @{ stdout = ''; stderr = [string]$ctx.reason; exit_code = -1; duration_s = 0 }
            dispatch_error = [string]$ctx.reason
            prompt_sent = ''
        }
    }

    $prompt = Build-DiffApplyPrompt -TaskDesc $TaskDesc -InputBlock $InputBlock `
        -Context $ctx -AllowedPaths $AllowedPaths -Limits $limits

    # Deliberately NO Push-Location, unlike the agentic path: this worker never
    # touches the filesystem — it is handed file text and returns text, and Baton
    # does the writing below. Setting cwd to the worktree would imply a filesystem
    # relationship this transport does not have. The asymmetry is intentional.
    $attemptResult = $null
    try {
        $attemptResult = if ($Dispatcher) { & $Dispatcher $Candidate $prompt $DepthTier }
                         else { Invoke-Fleet -Name $name -Prompt $prompt -Path $FleetPath -Tier $DepthTier -UsagePath $UsagePath -NoJournal }
    } catch {
        $msg = $_.Exception.Message
        $obs.apply_result = 'dispatch-error'
        $obs.verdict = 'fail'
        [void](Write-DiffApplyObservation -Row $obs -Path $ObservationPath)
        return @{
            result = @{ stdout = ''; stderr = $msg; exit_code = -1; duration_s = 0 }
            dispatch_error = $msg; prompt_sent = $prompt
        }
    }
    if ($null -eq $attemptResult) {
        $obs.apply_result = 'dispatch-error'
        $obs.verdict = 'fail'
        [void](Write-DiffApplyObservation -Row $obs -Path $ObservationPath)
        return @{
            result = @{ stdout = ''; stderr = 'dispatch returned no result'; exit_code = -1; duration_s = 0 }
            dispatch_error = 'dispatch returned no result'; prompt_sent = $prompt
        }
    }
    if ([int]$attemptResult.exit_code -ne 0) {
        # The provider itself failed; hand the result through untouched so the
        # caller's existing usage classification and failover logic see it verbatim.
        $obs.apply_result = 'dispatch-failed'
        $obs.verdict = 'fail'
        [void](Write-DiffApplyObservation -Row $obs -Path $ObservationPath)
        return @{ result = $attemptResult; dispatch_error = ''; prompt_sent = $prompt }
    }

    $stdout = [string]$attemptResult.stdout
    $duration = if ($null -ne $attemptResult.duration_s) { $attemptResult.duration_s } else { 0 }
    # Carry the dispatch's own usage observation onto a rebuilt failure result when
    # there is one: the DISPATCH succeeded (no quota/overflow event), only the work
    # product was unusable. Dropping it would make the caller reclassify a healthy
    # provider from a synthetic exit 1 and cool it down for a bad answer.
    $carriedUsage = $null
    if ($attemptResult -is [System.Collections.IDictionary]) {
        if ($attemptResult.Contains('usage_observation')) { $carriedUsage = $attemptResult['usage_observation'] }
    } elseif ($null -ne $attemptResult.PSObject.Properties['usage_observation']) {
        $carriedUsage = $attemptResult.usage_observation
    }
    $newFailure = {
        param([string]$Stderr)
        $r = [ordered]@{ stdout = $stdout; stderr = $Stderr; exit_code = 1; duration_s = $duration }
        if ($null -ne $carriedUsage) { $r['usage_observation'] = $carriedUsage }
        return @{ result = $r; dispatch_error = ''; prompt_sent = $prompt }
    }.GetNewClosure()

    $parsed = ConvertFrom-EditBlocks -Text $stdout
    $obs.parse_result = [string]$parsed.result
    $obs.blocks_emitted = @($parsed.blocks).Count
    if ([string]$parsed.result -ne 'ok') {
        # 'empty' — prose with no blocks — is a real FAILURE, not a no-change pass.
        # It has to be rejected here, at the parse layer: Invoke-EditBlockApply
        # returns ok=$true for an empty block list, so the applier will not catch it.
        $obs.verdict = 'fail'
        [void](Write-DiffApplyObservation -Row $obs -Path $ObservationPath)
        $detail = if ($parsed.error) { [string]$parsed.error } else { 'no SEARCH/REPLACE blocks in the model output' }
        return & $newFailure "diff-apply: parse $($parsed.result): $detail"
    }

    # The block cap is part of the SIZE ENVELOPE, and the envelope is how Baton
    # discovers how small a task has to be for a cheap model to succeed. An
    # advertised-but-unenforced cap makes that data meaningless: a model told
    # "emit at most 8 blocks" that emits 50 would have all 50 applied and the
    # observation would record a success at a size the envelope says is out of
    # bounds. Enforced here, after parsing and BEFORE applying, so the worktree is
    # left byte-identical. Same failure shape as the over-context path above,
    # including the literal 'diff-apply envelope' that Resolve-OutcomeRatingValue
    # matches to skip the capability rating — an oversized task is not evidence
    # about model quality.
    $maxBlocks = 8
    $maxBlocksVal = Get-DiffApplyField -Obj $limits -Name 'max_blocks'
    if ($null -ne $maxBlocksVal) {
        $mb = 0
        if ([int]::TryParse([string]$maxBlocksVal, [ref]$mb)) { $maxBlocks = $mb }
    }
    if ([int]$obs.blocks_emitted -gt $maxBlocks) {
        $capReason = "task exceeds diff-apply envelope: $($obs.blocks_emitted) blocks > limit $maxBlocks"
        $obs.apply_result = 'envelope-exceeded'
        $obs.verdict = 'fail'
        [void](Write-DiffApplyObservation -Row $obs -Path $ObservationPath)
        return @{
            result = @{ stdout = ''; stderr = $capReason; exit_code = -1; duration_s = 0 }
            dispatch_error = $capReason
            # Unlike the over-context refusal, this prompt WAS dispatched — report it
            # so the caller measures what was actually sent (the same invariant that
            # makes this function return prompt_sent at all).
            prompt_sent = $prompt
        }
    }

    $applied = Invoke-EditBlockApply -Worktree $Worktree -Blocks @($parsed.blocks) -AllowedPaths $AllowedPaths
    $obs.apply_result = [string]$applied.result
    $obs.blocks_applied = [int]$applied.blocks_applied
    if (-not $applied.ok) {
        # All-or-nothing: the worktree is byte-identical to before this attempt.
        $obs.verdict = 'fail'
        [void](Write-DiffApplyObservation -Row $obs -Path $ObservationPath)
        return & $newFailure "diff-apply: $($applied.result): $($applied.error)"
    }

    $obs.verdict = 'pass'
    [void](Write-DiffApplyObservation -Row $obs -Path $ObservationPath)
    return @{ result = $attemptResult; dispatch_error = ''; prompt_sent = $prompt }
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
        ((Resolve-CandidateEditMode -Candidate $_ -FleetPath $FleetPath) -ne 'none') -and
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
    <# Full worker prompt: optional bus inputs + Task: desc + scope brief + output
       instruction. The scope brief (#136) TELLS the worker what the oracle will
       enforce — advisory to the worker; the scope oracle remains the sole authority. #>
    param(
        [AllowEmptyString()][AllowNull()][string]$TaskDesc = '',
        [AllowEmptyString()][AllowNull()][string]$InputBlock = '',
        [AllowNull()][string[]]$AllowedPaths = @()
    )
    $desc = if ($null -eq $TaskDesc) { '' } else { [string]$TaskDesc }
    $core = "Task: $desc"
    if (-not [string]::IsNullOrWhiteSpace($InputBlock)) {
        # ADVISORY DATA, NOT AUTHORITY — see call site comment in New-AgenticSpawner.
        $core = $InputBlock.TrimEnd() + "`n`n" + $core
    }
    $scope = @($AllowedPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if ($scope.Count -gt 0) {
        $scopeList = $scope -join ', '
        $core = $core.TrimEnd() + "`n`n" +
            "Scope: create or modify files ONLY under these paths (relative to the repo root): $scopeList. " +
            "Any change outside them - including scratch, helper, or verification scripts at the repo root - " +
            "fails verification and voids this work. Run throwaway checks without writing files to the repo " +
            "(use stdout or a temp directory outside it)."
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
        # Total failover hops allowed for ONE task, counting a preflight reroute. Bounds
        # the walk so a fleet-wide outage costs a few dispatches, not one per provider.
        [ValidateRange(0, 20)][int]$MaxFailoverHops = 3,
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
        # via a platform field, so require source='fleet' before the eligibility test.
        $cands = @($raw | Where-Object { ($null -ne $_) -and ([string]$_.source -eq 'fleet') -and
            ((Resolve-CandidateEditMode -Candidate $_ -FleetPath $FleetPath) -ne 'none') })
        if ($cands.Count -lt 1) {
            # Message-only remedy (#127): name the stakes/tier collision; do NOT auto-escalate.
            # #124: audit per-provider exclusions to tell 'the roster cannot do this'
            # (static) from 'everyone who could is out right now' (usage -> labor
            # unavailable); the caller surfaces the distinction as a run status.
            $floor = Get-CapabilityCostTierFloor -Capability $cap -FleetPath $FleetPath
            $exclusions = @(Get-EditPoolExclusions -Capability $cap -TierCap $policy.max_cost_tier `
                -FleetPath $FleetPath -UsagePath $UsagePath)
            $whyZero = Format-ZeroCandidateWhy -Capability $cap -TierCap $policy.max_cost_tier `
                -Stakes $policy.stakes -Floor $floor -Exclusions $exclusions
            $laborOut = @($exclusions | Where-Object { [string]$_.stage -eq 'usage' }).Count -gt 0
            return @{
                ok = $false; spend = 0.0; chose = ''; why = $whyZero; alternatives = @()
                labor = $(if ($laborOut) { 'unavailable' } else { '' })
                exclusions = $exclusions
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
        # Scope brief (#136): name the task's allowed_paths in the worker prompt so the
        # sandbox the oracle enforces is one the worker can see. Rework tasks inherit
        # allowed_paths from the failing task and flow through this same call.
        $scopePaths = @()
        if ($null -ne $task.allowed_paths) { $scopePaths = @($task.allowed_paths | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        $prompt = Build-AgenticWorkerPrompt -TaskDesc ([string]$task.desc) -InputBlock $busInputs -AllowedPaths $scopePaths
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
                            # #124: the pool emptied POST-selection (preflight hold, no
                            # substitute) — same labor-unavailable flavor as zero candidates.
                            labor='unavailable'
                            exclusions=@([ordered]@{ name=[string]$originalPick.name; stage='usage'; reason='preflight hold (soft cap)'; reset_at=$null; eta=$null })
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
                                    # #124: original AND substitute both over cap — pool
                                    # emptied post-selection, labor-unavailable flavor.
                                    labor='unavailable'
                                    exclusions=@(
                                        [ordered]@{ name=[string]$originalPick.name; stage='usage'; reason='preflight hold (soft cap)'; reset_at=$null; eta=$null }
                                        [ordered]@{ name=[string]$pick.name; stage='usage'; reason='preflight hold (soft cap)'; reset_at=$null; eta=$null }
                                    )
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
        # d103: a text-transport provider with the diff_apply opt-in takes the same
        # task through a different door — Baton reads the files in and applies the
        # blocks it gets back. Everything after this branch (proof-by-diff, per-task
        # diff, usage observation, verification) is identical for both doors.
        $isDiffApply = (Resolve-CandidateEditMode -Candidate $pick -FleetPath $FleetPath) -eq 'diff-apply'
        $firstAttempt = if ($isDiffApply) {
            Invoke-DiffApplyAttempt -Candidate $pick -TaskDesc ([string]$task.desc) -InputBlock $busInputs `
                -AllowedPaths $scopePaths -DepthTier $policy.depth_tier -Worktree $Worktree `
                -FleetPath $FleetPath -UsagePath $UsagePath -RunDir $RunDir -TaskId ([string]$task.id) `
                -Dispatcher $Dispatcher
        } else {
            Invoke-AgenticDispatchAttempt -Candidate $pick -Prompt $prompt -DepthTier $policy.depth_tier `
                -Worktree $Worktree -FleetPath $FleetPath -UsagePath $UsagePath -Dispatcher $Dispatcher
        }
        $res = $firstAttempt.result
        # Measure the prompt that was ACTUALLY dispatched. On a diff-apply dispatch
        # $prompt (the agentic prompt) was built but never sent; reporting its size
        # would feed a wrong prompt_bytes into context-overflow detection, which is
        # what decides whether to fail over to a larger-context peer.
        $dispatchedPrompt = if ($isDiffApply) { [string]$firstAttempt.prompt_sent } else { $prompt }
        # Capture on success AND failure — a failed attempt's residue is what rework needs.
        Write-TaskBusOutput -RunDir $RunDir -TaskId ([string]$task.id) -Stdout $(if ($null -ne $res) { [string]$res.stdout } else { '' })
        $observation = Get-AgenticUsageObservation -Result $res -Worker ([string]$pick.name) -UsagePath $UsagePath `
            -PromptBytes (Get-Utf8ByteCount -Text $dispatchedPrompt)
        # (partial-diff detection now happens per hop inside the failover walk below,
        # since any attempt in the walk -- not only the first -- can dirty the worktree)

        # Cost-ordered failover WALK (#code-factory). THIS is the factory's labor path:
        # --execute always installs this spawner, so a walk that lives on
        # Invoke-TaskViaFleet (only reached when no spawner is supplied) never runs for
        # real execute labor. Two limits used to stall a task here anyway:
        #   * exactly ONE substitute was tried, so a second capped editor ended the task;
        #   * `-not $preflightRerouted` disabled dispatch failover entirely whenever the
        #     preflight had already hopped -- the likeliest case during a quota storm.
        # Now the task walks to successive untried peers until one produces a usable
        # attempt, the peer pool empties, or the hop budget is spent. A preflight reroute
        # counts as a hop, so $MaxFailoverHops bounds TOTAL hops per task, not per stage.
        #
        # hard_failover = quota/burst usage hop. context_overflow is NOT a usage lockout
        # (provider stays routable) but still earns a quality_first peer retry with a soft
        # preference for larger declared max_prompt_bytes.
        $hopLines = [System.Collections.Generic.List[string]]::new()
        if ($hopLine) { [void]$hopLines.Add([string]$hopLine) }
        $hops = if ($preflightRerouted) { 1 } else { 0 }
        while ($true) {
            $isContextOverflow = $observation -and ([string]$observation.classification -eq 'context_overflow')
            $shouldSubstitute = [int]$res.exit_code -ne 0 -and $observation -and
                $FailoverPolicy -eq 'quality_first' -and
                ($observation.hard_failover -or $isContextOverflow)
            if (-not $shouldSubstitute) { break }
            if ($hops -ge $MaxFailoverHops) {
                $advisoryLines.Add("failover budget spent ($hops hop(s)); $($pick.name) left holding the task")
                break
            }
            # Recomputed per hop: a later attempt can dirty the worktree too, and the
            # usage-failover event records whether THIS attempt left a partial diff.
            $attemptPostTree = Get-WorktreeTreeSha -Worktree $Worktree
            $hadPartialDiff = ($null -ne $preTree) -and ($null -ne $attemptPostTree) -and ($preTree -ne $attemptPostTree)
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
                    return $resultBase + @{ ok=$false; spend=0.0; chose=$pick.name; why=$why; alternatives=$alts }
                }
                # #124: quota-death emptied the pool mid-dispatch (no peer) — the
                # labor-unavailable flavor. Context overflow above is NOT: the roster
                # simply has no larger-context peer (config-shaped, not availability).
                $why = "usage failover: $($pick.name) -> no peer available (quality_first; $($observation.classification))"
                return $resultBase + @{
                    ok=$false; spend=0.0; chose=$pick.name; why=$why; alternatives=$alts
                    labor='unavailable'
                    exclusions=@([ordered]@{ name=[string]$pick.name; stage='usage'; reason="$($observation.classification) (no peer available)"; reset_at=[string]$observation.reset_at; eta=$null })
                }
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
            [void]$hopLines.Add([string]$hopLine)

            # A failover target may be a diff-apply provider too — same branch, and the
            # same "measure what was actually sent" rule.
            $subIsDiffApply = (Resolve-CandidateEditMode -Candidate $substitute -FleetPath $FleetPath) -eq 'diff-apply'
            $retryAttempt = if ($subIsDiffApply) {
                Invoke-DiffApplyAttempt -Candidate $substitute -TaskDesc ([string]$task.desc) -InputBlock $busInputs `
                    -AllowedPaths $scopePaths -DepthTier $retryPolicy.depth_tier -Worktree $Worktree `
                    -FleetPath $FleetPath -UsagePath $UsagePath -RunDir $RunDir -TaskId ([string]$task.id) `
                    -Dispatcher $Dispatcher
            } else {
                Invoke-AgenticDispatchAttempt -Candidate $substitute -Prompt $prompt -DepthTier $retryPolicy.depth_tier `
                    -Worktree $Worktree -FleetPath $FleetPath -UsagePath $UsagePath -Dispatcher $Dispatcher
            }
            $res = $retryAttempt.result
            $retryPrompt = if ($subIsDiffApply) { [string]$retryAttempt.prompt_sent } else { $prompt }
            Write-TaskBusOutput -RunDir $RunDir -TaskId ([string]$task.id) -Stdout $(if ($null -ne $res) { [string]$res.stdout } else { '' })
            # MUST be captured, not discarded: the loop condition re-tests $observation to
            # decide whether to hop again. Throwing this away would leave the previous
            # provider's verdict in place and walk on a stale classification forever.
            $observation = Get-AgenticUsageObservation -Result $res -Worker ([string]$substitute.name) -UsagePath $UsagePath `
                -PromptBytes (Get-Utf8ByteCount -Text $retryPrompt)
            $pick = $substitute
            $alts = $retryAlts
            $policy = $retryPolicy
            $resultBase = New-AgenticResultBase -Candidate $pick -Policy $policy -FleetPath $FleetPath
            $firstAttempt = $retryAttempt
            $hops++
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
        # Every hop, not just the last one: "a -> b -> c, all capped" is the legible
        # story of a quota storm, and reporting only the final hop hid the walk.
        $hopChain = if ($hopLines.Count -gt 0) { $hopLines -join '; ' } else { '' }
        if ([int]$res.exit_code -ne 0) {
            if ($hopChain) {
                $failureWhy = "$hopChain; substitute exit $($res.exit_code)"
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
            $successWhy = if ($hopChain) { "$hopChain; worktree diff grew" } else { "routed $cap -> $($pick.name); worktree diff grew" }
            if ($advisoryLines.Count -gt 0) { $successWhy += '; ' + ($advisoryLines -join '; ') }
            return $resultBase + @{ ok = $true; spend = 0.0; chose = $pick.name; why = $successWhy; alternatives = $alts }
        }
        $noChangeWhy = if ($hopChain) { "$hopChain; no changes" } else { "$($pick.name): no changes" }
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
       re-sending. Writes attempts.jsonl + verification.json (+ rework-evidence-N.md).
       -RatingsPath: where write-on-observe (#159) appends outcome ratings. Defaults to
       the knowledge-backed routing-ratings.jsonl. Hermetic tests should pass a temp
       path or set BATON_ROUTING_OBSERVE=off. #>
    param(
        [Parameter(Mandatory)][scriptblock]$InnerSpawner,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$FrozenContracts,
        $MaxRework = $null,
        [string]$RatingsPath = ''
    )
    $maxReworkOverride = $MaxRework
    $observeRatingsPath = if ($RatingsPath) { $RatingsPath } else { $script:DefaultRatingsPath }
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

        # #159 write-on-observe: terminal verification → at most one heuristic rating.
        # Never let a ratings write fail the labor run (try/catch + Add-CapabilityRating
        # already warns rather than throws). Gated by BATON_ROUTING_OBSERVE (default on).
        try {
            $runId = Split-Path -Leaf $RunDir
            $cap = if ($task.capability) { [string]$task.capability } else { 'code-gen' }
            $laborFlag = ''
            if ($final.inner -is [System.Collections.IDictionary]) {
                if ($final.inner.Contains('labor')) { $laborFlag = [string]$final.inner.labor }
            } elseif ($null -ne $final.inner.PSObject.Properties['labor']) {
                $laborFlag = [string]$final.inner.labor
            }
            $modelVer = ''
            if ($final.inner -is [System.Collections.IDictionary]) {
                if ($final.inner.Contains('model_version')) { $modelVer = [string]$final.inner.model_version }
                elseif ($final.inner.Contains('model')) { $modelVer = [string]$final.inner.model }
            } else {
                if ($null -ne $final.inner.PSObject.Properties['model_version']) {
                    $modelVer = [string]$final.inner.model_version
                } elseif ($null -ne $final.inner.PSObject.Properties['model']) {
                    $modelVer = [string]$final.inner.model
                }
            }
            $observeArgs = @{
                RunId        = $runId
                TaskId       = [string]$task.id
                Capability   = $cap
                Candidate    = [string]$final.inner.chose
                Verification = $verObj
                Why          = $why
                Labor        = $laborFlag
                ModelVersion = $modelVer
            }
            if ($observeRatingsPath) { $observeArgs.RatingsPath = $observeRatingsPath }
            [void](Add-OutcomeRating @observeArgs)
        } catch {
            Write-Warning "routing observe (executor): $($_.Exception.Message)"
        }

        return $result
    }.GetNewClosure()
}
