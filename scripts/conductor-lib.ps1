#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Conductor engine (/baton:go). Parses a model-produced task DAG, walks it under
  two interrupt guards (budget cap + reversible:false), logs event/decision
  ledgers, and renders a report. Pure layer + seamed Invoke-Conductor.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-go.ps1 wraps it for
  /baton:go. routing-lib brings Select-Capability and (via fleet-lib) Invoke-Fleet.
.NOTES
  See docs/superpowers/specs/2026-06-18-conductor-go-mode-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability (+ fleet-lib: Invoke-Fleet)
. "$PSScriptRoot/gate-lib.ps1"   # Invoke-AcceptanceGate for the acceptance phase (d058)
. "$PSScriptRoot/plan-gate-lib.ps1"   # Invoke-PlanGate for the opt-in Plan Gate phase (d080).
                                       # Re-sources gate-lib (harmless in PS — functions just redefine).
. "$PSScriptRoot/effective-cost-lib.ps1"   # run-level effective cost (slice 1)
. "$PSScriptRoot/cost-resolver-lib.ps1"   # realized-cost metering (slice 2)
. "$PSScriptRoot/prompt-pool-lib.ps1"   # Slice B: live shadow A/B pool bookkeeping
. "$PSScriptRoot/verification-lib.ps1"   # Test-DiffFilesInAllowedPaths (#125 matcher) for acceptance-rework scope
. "$PSScriptRoot/officers-lib.ps1"   # Efficiency (never blocks) + VRAM claim for local labor

function New-RunId {
    <# Second-resolution IDs collide when Maestro/screens fan out multiple
       fleet-go processes in the same second (crossplatform Ox fan-out 2026-08-22).
       Append milliseconds + 4 hex chars so parallel spawns get unique worktrees. #>
    param([datetime]$Now = (Get-Date))
    $suffix = '{0:x4}' -f (Get-Random -Maximum 0x10000)
    return 'go-' + $Now.ToString('yyyy-MM-ddTHH-mm-ss-fff') + '-' + $suffix
}

function Get-JsonBlock {
    <# First '{' to last '}' from a possibly fenced/prose-wrapped reply; '' if none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open = $Raw.IndexOf('{'); $close = $Raw.LastIndexOf('}')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function Get-JsonBlocks {
    <# Every balanced top-level {...} candidate in a reply, in order (string-aware
       depth scan so braces inside JSON string values do not split a block). Needed
       for providers like `codex exec` that echo the prompt (which itself carries a
       JSON schema) before the answer — the greedy Get-JsonBlock spans echo+answer
       into one invalid blob. A mis-scanned candidate simply fails ConvertFrom-Json
       downstream and is skipped. Emits blocks to the pipeline (callers collect
       with @() — no unary-comma wrap, per the house rule). #>
    param([Parameter(Mandatory)][string]$Raw)
    $blocks = [System.Collections.ArrayList]@()
    $depth = 0; $blockStart = -1; $inStr = $false; $escaped = $false
    for ($i = 0; $i -lt $Raw.Length; $i++) {
        $ch = $Raw[$i]
        if ($inStr) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { if ($depth -gt 0) { $inStr = $true } }
        elseif ($ch -eq '{') { if ($depth -eq 0) { $blockStart = $i }; $depth++ }
        elseif ($ch -eq '}') {
            if ($depth -gt 0) {
                $depth--
                if ($depth -eq 0 -and $blockStart -ge 0) {
                    [void]$blocks.Add($Raw.Substring($blockStart, $i - $blockStart + 1))
                    $blockStart = -1
                }
            }
        }
    }
    return $blocks.ToArray()
}

function ConvertTo-PlanObject {
    <# Parse a planner reply into a normalized plan hashtable, or $null when there
       is no valid JSON object or no tasks. Tasks get defaulted fields.
       Candidate order (v1.11.1, multi-model): the greedy whole-span block first
       (the historical fast path — one clean/fenced JSON reply), then balanced
       blocks LAST-first, because a model's answer follows any prompt echo. The
       first candidate that parses AND carries tasks wins. #>
    param([Parameter(Mandatory)][string]$RawStdout)
    $candidates = [System.Collections.ArrayList]@()
    $greedy = Get-JsonBlock -Raw $RawStdout
    if ($greedy) { [void]$candidates.Add($greedy) }
    $balanced = @(Get-JsonBlocks -Raw $RawStdout)
    for ($bi = $balanced.Count - 1; $bi -ge 0; $bi--) { [void]$candidates.Add($balanced[$bi]) }
    $o = $null
    foreach ($block in $candidates) {
        try { $parsed = $block | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $parsed.tasks) { continue }
        # Reject the planner prompt's own echoed SCHEMA (a provider that dies after
        # echoing would otherwise hand us its placeholder example as a "plan"):
        # the schema's est_cost_tier placeholder "local|free|paid" is the signature.
        $isSchemaEcho = $false
        foreach ($pt in @($parsed.tasks)) {
            if ($pt.est_cost_tier -and (([string]$pt.est_cost_tier) -match '\|')) { $isSchemaEcho = $true; break }
            $plannedStakes = [string]$pt.stakes
            if (-not [string]::IsNullOrWhiteSpace($plannedStakes)) {
                if ($plannedStakes -notin @('low','standard','high') -or
                    [string]::IsNullOrWhiteSpace([string]$pt.stakes_basis)) {
                    $isSchemaEcho = $true
                    break
                }
            }
        }
        if ($isSchemaEcho) { continue }
        $o = $parsed; break
    }
    if ($null -eq $o) { return $null }
    $tasks = foreach ($t in @($o.tasks)) {
        [pscustomobject]@{
            id            = [string]$t.id
            desc          = [string]$t.desc
            command       = [string]$t.command
            capability    = [string]$t.capability
            model_pick    = [string]$t.model_pick
            depends_on    = @($t.depends_on | Where-Object { $_ })
            est_cost_tier = if ($t.est_cost_tier) { [string]$t.est_cost_tier } else { 'free' }
            reversible    = if ($null -eq $t.reversible) { $true } else { [bool]$t.reversible }
            verify_profile = if ($t.verify_profile) { [string]$t.verify_profile } else { '' }
            allowed_paths  = @($t.allowed_paths | Where-Object { $_ } | ForEach-Object { [string]$_ })
            stakes        = if ([string]::IsNullOrWhiteSpace([string]$t.stakes)) { 'standard' } else { [string]$t.stakes }
            stakes_basis  = if ([string]::IsNullOrWhiteSpace([string]$t.stakes)) { 'legacy plan omitted stakes' } else { [string]$t.stakes_basis }
        }
    }
    if (@($tasks).Count -lt 1) { return $null }
    return @{
        run_id     = [string]$o.run_id
        goal       = [string]$o.goal
        budget_cap = if ($null -eq $o.budget_cap) { $null } else { [double]$o.budget_cap }
        tasks      = @($tasks)
    }
}

function Get-WorktreeTopLevelDirs {
    <# Directory names at the worktree root (skip .git). Fail-soft: missing path
       or unlistable dir → empty array, never throw. Used to turn a planner's
       absolute ~/dev/... path into a worktree-relative allowed_paths entry. #>
    param([string]$Worktree)
    if ([string]::IsNullOrWhiteSpace($Worktree)) { return @() }
    if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) { return @() }
    try {
        return @(
            Get-ChildItem -LiteralPath $Worktree -Directory -Force -ErrorAction Stop |
                Where-Object { $_.Name -ne '.git' } |
                ForEach-Object { [string]$_.Name }
        )
    } catch { return @() }
}

function ConvertTo-WorktreeRelativeAllowedPath {
    <# Turn one planner allowed_paths entry into a worktree-relative path.
       Relative input is normalized (forward slashes, optional trailing / kept).
       Absolute / ~/dev / drive-letter input is rewritten when it sits under
       -Worktree, or when a suffix starts at a known top-level directory
       (scripts/, docs/, …). Unconvertible absolute paths return $null so the
       caller can keep the original and let Get-DiffApplyContext fail loud. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Worktree = '',
        [string[]]$TopLevelDirs = @()
    )
    $raw = [string]$Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $hadSlash = $raw.EndsWith('/') -or $raw.EndsWith('\')
    $p = $raw.Trim()

    if ($p -eq '~') {
        $p = [string]$HOME
    } elseif ($p.StartsWith('~/') -or $p.StartsWith('~\')) {
        $p = [System.IO.Path]::Combine([string]$HOME, $p.Substring(2))
    }

    $isAbs = [System.IO.Path]::IsPathRooted($p) -or
             ($p -match '^[A-Za-z]:') -or
             $p.StartsWith('\\') -or
             $p.StartsWith('//')

    if (-not $isAbs) {
        $rel = $p.Replace('\', '/')
        if ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }
        if ($hadSlash -and -not $rel.EndsWith('/')) { $rel = $rel + '/' }
        return $rel
    }

    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($p) } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($full)) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($Worktree)) {
        try {
            $root = [System.IO.Path]::GetFullPath($Worktree).TrimEnd('\', '/')
            $sep = [System.IO.Path]::DirectorySeparatorChar
            if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($hadSlash) { return './' }
                return '.'
            }
            if ($full.StartsWith(($root + $sep), [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $full.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
                if ($hadSlash -and -not $rel.EndsWith('/')) { $rel = $rel + '/' }
                return $rel
            }
        } catch { }
    }

    $segments = @($full -split '[\\/]' | Where-Object { $_ -ne '' })
    $topSet = @{}
    foreach ($d in @($TopLevelDirs)) {
        $name = [string]$d
        if ($name.EndsWith('/') -or $name.EndsWith('\')) { $name = $name.TrimEnd('\', '/') }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $topSet[$name.ToLowerInvariant()] = $true
        }
    }
    if ($topSet.Count -gt 0) {
        for ($i = 0; $i -lt $segments.Count; $i++) {
            if ($topSet.ContainsKey($segments[$i].ToLowerInvariant())) {
                $rel = ($segments[$i..($segments.Count - 1)] -join '/')
                if ($hadSlash -and -not $rel.EndsWith('/')) { $rel = $rel + '/' }
                return $rel
            }
        }
    }
    return $null
}

function Repair-PlanAllowedPaths {
    <# Rewrite every task's allowed_paths to worktree-relative form. Unconvertible
       absolute entries are kept so Get-DiffApplyContext can fail loud instead of
       silently emptying Ox context. Empty -RepoPath still normalizes slashes. #>
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$RepoPath = ''
    )
    if ($null -eq $Plan) { return $Plan }
    $top = @(Get-WorktreeTopLevelDirs -Worktree $RepoPath)
    foreach ($t in @($Plan.tasks)) {
        $next = [System.Collections.Generic.List[string]]::new()
        foreach ($p in @($t.allowed_paths)) {
            $s = [string]$p
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $converted = ConvertTo-WorktreeRelativeAllowedPath -Path $s -Worktree $RepoPath -TopLevelDirs $top
            if ([string]::IsNullOrWhiteSpace($converted)) { $next.Add($s) }
            else { $next.Add($converted) }
        }
        $t.allowed_paths = @($next)
    }
    return $Plan
}

function Resolve-TaskOrder {
    <# Stable topological order via Kahn's algorithm. Throws on a dependency cycle
       or a dependency on an unknown id. Ready tasks are emitted in original order. #>
    param([Parameter(Mandatory)][array]$Tasks)
    $byId = @{}; foreach ($t in $Tasks) { if ($t.id) { $byId[$t.id] = $t } }
    $indeg = @{}; foreach ($t in $Tasks) { $indeg[$t.id] = 0 }
    foreach ($t in $Tasks) {
        foreach ($d in @($t.depends_on)) {
            if (-not $byId.ContainsKey($d)) { throw "Task '$($t.id)' depends on unknown id '$d'." }
            $indeg[$t.id]++
        }
    }
    $ordered = [System.Collections.ArrayList]@()
    $ready   = [System.Collections.ArrayList]@()
    foreach ($t in $Tasks) { if ($indeg[$t.id] -eq 0) { [void]$ready.Add($t.id) } }
    while ($ready.Count -gt 0) {
        $id = $ready[0]; $ready.RemoveAt(0)
        [void]$ordered.Add($byId[$id])
        foreach ($t in $Tasks) {
            if (@($t.depends_on) -contains $id) {
                $indeg[$t.id]--
                if ($indeg[$t.id] -eq 0) { [void]$ready.Add($t.id) }
            }
        }
    }
    if ($ordered.Count -ne $Tasks.Count) { throw 'Plan has a dependency cycle.' }
    return ,([array]$ordered)
}

function Get-TaskCostEstimate {
    <# Coarse v1 estimate: paid -> per-call figure; local/free/unknown -> 0. #>
    param([Parameter(Mandatory)][string]$Tier, [double]$PaidPerCall = 0.05)
    if ($Tier -eq 'paid') { return $PaidPerCall }
    return 0.0
}

function Test-BudgetExceeded {
    <# True when cumulative + this task's estimate would cross the cap. Null cap -> never. #>
    param([double]$CumulativeSpend, [double]$TaskEstimate, $BudgetCap)
    if ($null -eq $BudgetCap) { return $false }
    return (($CumulativeSpend + $TaskEstimate) -gt [double]$BudgetCap)
}

function Test-TaskDestructive {
    <# A node tagged reversible:false always interrupts. #>
    param([Parameter(Mandatory)]$Task)
    return ($Task.reversible -eq $false)
}

function New-RunEvent {
    <# Pure factory for an events.jsonl record. ($EventObj, not $Event: $Event is a
       PowerShell automatic variable.) #>
    param(
        [string]$TaskId = '',
        [Parameter(Mandatory)][string]$Kind,
        [string]$Message = '',
        [string]$Level = 'info',
        [datetime]$Now = (Get-Date)
    )
    return [ordered]@{
        ts      = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        level   = $Level
        task_id = $TaskId
        kind    = $Kind
        message = $Message
    }
}

function New-RunDecision {
    <# Pure factory for a decisions.jsonl record (an autonomous guess + alternatives). #>
    param(
        [string]$TaskId = '',
        [Parameter(Mandatory)][string]$Chose,
        [string[]]$Alternatives = @(),
        [string]$Why = '',
        [string]$CostTier = '',
        [datetime]$Now = (Get-Date),
        [ValidateSet('low','standard','high')][string]$Stakes,
        [string]$StakesBasis,
        [ValidateSet('low','med','high')][string]$DepthTier,
        [bool]$DepthApplied,
        [ValidateSet('economy','champion')][string]$SelectionMode,
        [ValidateSet('local','free','paid')][string]$TierCap,
        [ValidateSet('local','free','paid')][string]$SelectedCostTier
    )
    $record = [ordered]@{
        ts           = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        task_id      = $TaskId
        chose        = $Chose
        alternatives = @($Alternatives)
        why          = $Why
        cost_tier    = $CostTier
    }
    $optional = [ordered]@{
        Stakes = 'stakes'; StakesBasis = 'stakes_basis'; DepthTier = 'depth_tier'
        DepthApplied = 'depth_applied'; SelectionMode = 'selection_mode'
        TierCap = 'tier_cap'; SelectedCostTier = 'selected_cost_tier'
    }
    foreach ($parameterName in $optional.Keys) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $record[$optional[$parameterName]] = $PSBoundParameters[$parameterName]
        }
    }
    return $record
}

function Add-RunEvent {
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)]$EventObj)
    $line = ($EventObj | ConvertTo-Json -Compress -Depth 6)
    Add-Content -LiteralPath (Join-Path $RunDir 'events.jsonl') -Value $line -Encoding utf8NoBOM
}

function Add-RunDecision {
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)]$Decision)
    $line = ($Decision | ConvertTo-Json -Compress -Depth 6)
    Add-Content -LiteralPath (Join-Path $RunDir 'decisions.jsonl') -Value $line -Encoding utf8NoBOM
}

function Initialize-RunDir {
    param([string]$RunId = (New-RunId), [string]$Root)
    if (-not $Root) { $Root = Join-Path (Get-BatonHome) 'runs' }
    $dir = Join-Path $Root $RunId
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Format-RunReport {
    <# Plain-English run report rendered from the plan + decision ledger. #>
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [array]$Decisions = @(),
        [double]$Spend = 0.0,
        [string]$Status = 'completed',
        [string]$PendingTaskId = ''
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Conductor run — $($Plan.run_id)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Goal:** $($Plan.goal)")
    [void]$sb.AppendLine("**Status:** $Status")
    if (($Status -ne 'completed') -and $PendingTaskId) { [void]$sb.AppendLine("**Paused at:** $PendingTaskId") }
    [void]$sb.AppendLine(("**Spend:** {0:0.00}" -f $Spend))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Tasks')
    foreach ($t in @($Plan.tasks)) {
        $tag = if ($t.capability) { "$($t.command)/$($t.capability)" } else { $t.command }
        [void]$sb.AppendLine("- $($t.id): $($t.desc) [$tag] ($($t.est_cost_tier))")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Decisions')
    if (@($Decisions).Count -eq 0) { [void]$sb.AppendLine('(none recorded)') }
    foreach ($d in @($Decisions)) {
        $alt = if (@($d.alternatives).Count) { " (alts: $((@($d.alternatives)) -join ', '))" } else { '' }
        $policy = if ($d.stakes) {
            $applied = if ($d.depth_applied) { 'applied' } else { 'not applied' }
            " [stakes: $($d.stakes) — $($d.stakes_basis); depth: $($d.depth_tier) ($applied); mode: $($d.selection_mode); cap: $($d.tier_cap); selected tier: $($d.selected_cost_tier)]"
        } else { '' }
        [void]$sb.AppendLine("- $($d.task_id): chose **$($d.chose)** — $($d.why)$alt$policy")
    }
    return $sb.ToString().TrimEnd()
}

function Format-LaborSection {
    <# '## Labor' report section for a labor-unavailable halt (#124): plain-language
       cause + known per-provider availability, so an empty labor pool never reads
       as a verification/implementation defect in report.md. Wording is seam-
       neutral: the halt may be pre-dispatch (zero candidates, preflight hold) or
       MID-dispatch (quota-death with no peer, possibly after partial labor) — no
       'before dispatch' claims. Cell text is pipe/newline-escaped: provider names
       and failure classifications are data, not markdown. #>
    param([Parameter(Mandatory)]$Result)
    $esc = { param($v) (([string]$v) -replace '\|', '/') -replace "`r?`n", ' ' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Labor')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('No edit-eligible worker was available to finish this task — the run halted on labor availability. This is an availability problem, not an implementation defect.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Why: $(& $esc $Result.why)")
    $excl = @($Result.exclusions)
    if ($excl.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Known exclusions (may be partial on post-selection halts):')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Provider | Stage | Reason | Reset |')
        [void]$sb.AppendLine('|---|---|---|---|')
        foreach ($e in $excl) {
            $reset = if ($e.eta) { [string]$e.eta } elseif ($e.reset_at) { [string]$e.reset_at } else { '' }
            [void]$sb.AppendLine("| $(& $esc $e.name) | $(& $esc $e.stage) | $(& $esc $e.reason) | $(& $esc $reset) |")
        }
    }
    return $sb.ToString().TrimEnd()
}

function Resolve-GateArtifact {
    <# The artifact text to gate: literal -Artifact wins; else `git diff <range>` for
       -Diff; else ''. A git failure returns '' (fail-open -> the phase no-ops). #>
    param([string]$Artifact, [string]$Diff)
    if (-not [string]::IsNullOrWhiteSpace($Artifact)) { return $Artifact }
    if (-not [string]::IsNullOrWhiteSpace($Diff)) {
        try {
            $out = & git diff $Diff 2>$null
            if ($LASTEXITCODE -ne 0) { return '' }
            return (@($out) -join "`n")
        } catch { return '' }
    }
    return ''
}

function Build-AcceptanceReworkEvidenceText {
    <# Evidence-only packaging for acceptance needs-polish rework. Engine invents
       nothing — repackages verdict/reason/polish_brief/findings. #>
    param([Parameter(Mandatory)]$Gate)
    $parts = [System.Collections.Generic.List[string]]::new()
    [void]$parts.Add("Acceptance verdict: $([string]$Gate.verdict)")
    if ($Gate.reason) { [void]$parts.Add("Reason: $([string]$Gate.reason)") }
    $brief = [string]$Gate.polish_brief
    if (-not [string]::IsNullOrWhiteSpace($brief)) {
        [void]$parts.Add($brief)
    } else {
        foreach ($f in @($Gate.findings)) {
            if ($null -eq $f) { continue }
            [void]$parts.Add("[$([string]$f.severity)] $([string]$f.area): $([string]$f.summary)")
        }
    }
    return ($parts -join "`n")
}

function Format-AcceptanceSection {
    <# Render the `## Acceptance` markdown block from a gate result (ordered or hashtable).
       Polish brief only when verdict != accept. #>
    param([Parameter(Mandatory)]$Gate)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Acceptance')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Verdict:** $($Gate.verdict)")
    if ($Gate.reason) { [void]$sb.AppendLine("**Reason:** $($Gate.reason)") }
    $c = $Gate.counts
    if ($c) { [void]$sb.AppendLine("**Findings:** $($c.critical) critical, $($c.important) important, $($c.minor) minor") }
    # #code-factory: a panel that lost a review lens, paid above its requested tier, or
    # failed a provider over must SAY SO in the operator-facing report. These used to be
    # discoverable only by reading acceptance.json — which is how the shipped roster's
    # two cheap roles went missing from every run without anyone noticing.
    $lostRoles = @($Gate.degraded_roles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($lostRoles.Count -gt 0) {
        [void]$sb.AppendLine("**DEGRADED — review lens(es) NOT run:** $($lostRoles -join ', ')")
    }
    $relaxed = @($Gate.tier_relaxed_roles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($relaxed.Count -gt 0) {
        [void]$sb.AppendLine("**Cost note — role(s) run above their requested cheap tier:** $($relaxed -join ', ')")
    }
    foreach ($note in @($Gate.failover_notes)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$note)) { [void]$sb.AppendLine("**Provider failover:** $note") }
    }
    if (($Gate.verdict -ne 'accept') -and $Gate.polish_brief) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Polish brief')
        [void]$sb.AppendLine([string]$Gate.polish_brief)
    }
    return $sb.ToString().TrimEnd()
}

function Format-VerificationSection {
    <# The Gemini CLI narration block (adjudication A2): per verified task, route ->
       worker -> check -> retry -> proves, read from tasks/<id>/verification.json.
       Returns '' when no task was verified (section omitted). #>
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][hashtable]$Plan)
    $lines = [System.Collections.ArrayList]@()
    foreach ($t in @($Plan.tasks)) {
        $vp = Join-Path $RunDir "tasks/$($t.id)/verification.json"
        if (-not (Test-Path -LiteralPath $vp)) { continue }
        try { $v = Get-Content -Raw -LiteralPath $vp | ConvertFrom-Json } catch { continue }
        $mark = if ([string]$v.verdict -eq 'pass') { "PASS (grade $($v.grade))" } else { "FAIL ($($v.failure_category))" }
        $reworkN = 0
        if ($null -ne $v.rework_cycles) { try { $reworkN = [int]$v.rework_cycles } catch { $reworkN = 0 } }
        elseif ($v.retried) { $reworkN = 1 }
        $retry = if ($reworkN -gt 0) { " after $reworkN rework" } else { '' }
        [void]$lines.Add("- $($t.id): $mark$retry — proves: $($v.proves)")
    }
    if (@($lines).Count -eq 0) { return '' }
    return "## Verification`n" + (@($lines) -join "`n")
}

# Fail-open fallback for Build-PlannerPrompt: the exact conductor-planner.txt
# template text, baked in so a missing/corrupt/malformed prompt file on disk
# can never take the planner phase down. Kept in sync by hand with
# prompts/conductor-planner.txt (read-only reference).
$script:DefaultPlannerPrompt = @'
You are a planning orchestrator for an autonomous software conductor. Break the
GOAL into an ordered task DAG that sequences existing Baton building blocks
(triage, research-gate, code-decompose, code-parallel, code-merge) and fleet
capabilities. Respond with ONLY valid JSON matching this schema — no prose, no fences.

Schema:
{{schema}}

Rules: give each task a unique id; use depends_on to order; set reversible=false
ONLY for steps that commit to master, force-push, delete outside a worktree, or
publish externally; prefer the cheapest est_cost_tier AT WHICH AN ELIGIBLE PROVIDER
EXISTS — see the capability tier floors in the evidence; never set a task's
est_cost_tier below its capability's floor. Set stakes
to low for narrow, reversible, low-blast-radius work; standard for ordinary bounded
feature or bugfix work; high for security/privacy/auth, migrations, release/publish,
cross-cutting architecture, or other high-cost-to-reverse work. stakes_basis must be
one concrete sentence naming the risk or size signal. Use the evidence to avoid
planning work that already exists.

{{evi}}

## Goal
{{Goal}}
'@

function Test-PlannerProviderEditEligible {
    <# Mirror of Test-ProviderEditCapable (fleet-executor-lib.ps1 / d078+d091+d103)
       for the planner evidence path only — keeps conductor-lib free of the executor
       import. Two independent ways to be edit-eligible, matching the executor pair:
        - Test-ProviderAgentic — the provider brings its own filesystem harness:
          explicit agentic flag wins, else platform ∈ {claude,codex,gemini}. The d091
          veto stands: http / stdio-json kinds are never agentic, marker or not.
        - Test-ProviderDiffApply — a http / stdio-json provider that explicitly opts
          in with `diff_apply: true`, so Baton applies its edits for it (d103/#168).
       Kept in sync by hand; the agreement drift guard lives in
       test-fleet-executor-lib.ps1 (the EA case table). #>
    param([Parameter(Mandatory)]$Provider)
    if ([string]$Provider.kind -in @('http', 'stdio-json')) { return ($Provider.diff_apply -eq $true) }
    if ($null -ne $Provider.agentic) { return [bool]$Provider.agentic }
    return (([string]$Provider.platform) -in @('claude', 'codex', 'gemini'))
}

function Build-PlannerPrompt {
    <# Instruct a model to decompose the goal into a task DAG (strict JSON).
       Fail-open + injection-safe:
        - Resolution order: the BATON_HOME copy first (the live copy, possibly
          tuned by the prompt optimizer), then the repo's $PSScriptRoot/../prompts
          copy as a fallback.
        - If neither file exists, is unreadable, or is missing any of the
          required literal placeholders, fall back to $script:DefaultPlannerPrompt
          — this function never throws.
        - Substitution uses [string]::Replace, NOT -replace: $Goal is untrusted
          user text, and a regex replacement would treat literal '$1'/'$&' in the
          goal as backreferences and corrupt the prompt. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string[]]$RegistryLines = @(),
        [string]$Template,
        [string]$RepoPath,
        [string]$FleetPath
    )
    $schema = @'
{
  "run_id": "<id>",
  "goal": "<the goal>",
  "budget_cap": null,
  "tasks": [
    { "id": "t1", "desc": "<what>", "command": "<baton command or empty>",
      "capability": "<ROUTING capability: code-gen for creating/editing files or code, code-transform, reasoning, research, summarize, triage, review — or empty. NEVER a baton command name>",
      "model_pick": "<model or empty>",
      "depends_on": [], "est_cost_tier": "local|free|paid", "reversible": true,
      "stakes": "low|standard|high", "stakes_basis": "<one concrete risk/size sentence>",
      "verify_profile": "<REQUIRED for code-gen/code-transform when verification is on: a profile name from the target repo's .baton/verification.json (see evidence); empty otherwise>",
      "allowed_paths": ["<exact worktree-relative file paths, OR a directory prefix ending in '/' (e.g. \"app/\"); prefer naming concrete files when known; use the target repo's real top-level directories from the evidence (never guess); NEVER emit absolute, drive-letter, or ~ paths (/Users/..., D:\\Dev\\..., ~/dev/...) — those empty Ox diff-apply context; * globs are NOT supported on this path (a plan with scripts/* fails closed here; fleet-backlog uses globs for the same field name elsewhere); empty = unrestricted (avoid for code-gen)>"] }
  ]
}

allowed_paths MUST be worktree-relative (scripts/foo.ps1, docs/). Absolute ~/dev host paths are rejected at diff-apply.
prefer the cheapest est_cost_tier AT WHICH AN ELIGIBLE PROVIDER EXISTS — see the capability tier floors in the evidence; never set a task's est_cost_tier below its capability's floor.
Stakes classification: low for narrow, reversible, low-blast-radius work;
standard for ordinary bounded feature or bugfix work; high for security/privacy/auth,
migrations, release/publish, cross-cutting architecture, or high-cost-to-reverse work.
stakes_basis is one concrete sentence naming the risk or size signal.
Every code-gen/code-transform task must name a verify_profile from the available list when one exists.
A failing-test + fix pair must be ONE task (per-task verification fails closed on a deliberately-red intermediate task).
'@
    $evi = if ($RegistryLines.Count) {
        "Tools already wired locally:`n" + (($RegistryLines | ForEach-Object { "- $_" }) -join "`n")
    } else { 'Tools already wired locally: (none)' }

    # Fail-soft: surface profile names from the target repo's HEAD config so the planner
    # can emit verify_profile. No repo / no config / unparseable => no line, never throw.
    if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
        try {
            $rawCfg = & git -C $RepoPath show 'HEAD:.baton/verification.json' 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace((@($rawCfg) -join ''))) {
                $doc = (@($rawCfg) -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                $names = @()
                if ($doc -is [hashtable] -and $doc.profiles -is [hashtable]) {
                    $names = @($doc.profiles.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object)
                }
                if ($names.Count -gt 0) {
                    $evi = $evi + "`nVerification profiles available in the target repo: " + ($names -join ', ')
                }
            }
        } catch { }
        # Fail-soft: cheap repo-layout facts so the planner can name real allowed_paths
        # prefixes instead of guessing (e.g. "src" when code lives under "app/").
        # --full-tree: ls-tree is CWD-relative without it; RepoPath may be a subdir.
        # No repo / not a git repo / command failure => no line, never throw. Cap at 20.
        # Filter: drop hostile names (len>64 or chars outside [\w.\-]); git C-escapes
        # control chars, but we do not rely on that silently.
        try {
            $topDirs = @(& git -C $RepoPath ls-tree --full-tree -d --name-only HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $topDirs.Count -gt 0) {
                $safeDirs = @(
                    $topDirs | ForEach-Object { [string]$_ } |
                        Where-Object { $_ -and $_.Length -le 64 -and $_ -match '^[\w.\-]+$' }
                )
                if ($safeDirs.Count -gt 0) {
                    $capped = @($safeDirs | Select-Object -First 20)
                    $layoutLine = $capped -join ', '
                    if ($safeDirs.Count -gt 20) { $layoutLine = $layoutLine + ', ... (truncated)' }
                    $evi = $evi + "`nTarget repo top-level directories: " + $layoutLine
                }
            }
        } catch { }
    }

    # Fail-soft (#127): capability tier floors from the live fleet so the planner
    # never emits est_cost_tier below a tier that actually has an eligible provider.
    # Missing/unparseable fleet.yaml => no line, never throw. code-gen/code-transform
    # floors count only edit-eligible providers (mirrors Test-ProviderAgentic).
    if (-not [string]::IsNullOrWhiteSpace($FleetPath)) {
        try {
            if (Test-Path -LiteralPath $FleetPath) {
                $fleetProviders = @(Read-Fleet -Path $FleetPath)
                $generalCaps = @(Get-GeneralCapabilities -FleetPath $FleetPath)
                # Mirror Select-Capability context floors (routing-lib Get-CapabilityFloors
                # + `$p.context < floor`). Fail-soft if floors helper is out of scope.
                $capFloors = @{}
                if (Get-Command Get-CapabilityFloors -ErrorAction SilentlyContinue) {
                    $capFloors = Get-CapabilityFloors -FleetPath $FleetPath
                }
                # Fixed planner vocabulary (schema + plan-review) so UNAVAILABLE is visible.
                $floorCaps = @('code-gen', 'code-transform', 'research', 'review', 'plan-review', 'reasoning', 'summarize', 'triage')
                $floorParts = [System.Collections.Generic.List[string]]::new()
                foreach ($floorCap in $floorCaps) {
                    $bestRank = 99
                    $bestTier = $null
                    foreach ($prov in $fleetProviders) {
                        if ($prov.enabled -ne $true) { continue }
                        $claims = $prov.capabilities
                        $claimsCap = if ($null -ne $claims) { @($claims) -contains $floorCap }
                                     else { $generalCaps -contains $floorCap }
                        if (-not $claimsCap) { continue }
                        if ($floorCap -in @('code-gen', 'code-transform')) {
                            if (-not (Test-PlannerProviderEditEligible -Provider $prov)) { continue }
                        }
                        # Same as Select-Capability: known-too-small context disqualifies;
                        # unknown/missing context never does.
                        if ($capFloors.ContainsKey($floorCap) -and $prov.context) {
                            if ([int]$prov.context -lt $capFloors[$floorCap]) { continue }
                        }
                        $tierName = [string]$prov.cost_tier
                        if ($tierName -notin @('local', 'free', 'paid')) { continue }
                        $rank = Get-CostTierRank $tierName
                        if ($rank -lt $bestRank) { $bestRank = $rank; $bestTier = $tierName }
                    }
                    if ($null -eq $bestTier) { [void]$floorParts.Add("${floorCap}=UNAVAILABLE") }
                    else { [void]$floorParts.Add("${floorCap}=$bestTier") }
                }
                if ($floorParts.Count -gt 0) {
                    $evi = $evi + "`nCapability tier floors (cheapest tier with an eligible provider): " + ($floorParts -join ', ')
                }
            }
        } catch { }
    }

    $requiredPlaceholders = @('{{schema}}', '{{evi}}', '{{Goal}}')
    # Slice B: a caller-supplied template (the shadow challenger) wins when it
    # carries all placeholders; anything less falls through to the live chain.
    $resolved = $null
    if (-not [string]::IsNullOrEmpty($Template)) {
        $hasAllOverride = $true
        foreach ($ph in $requiredPlaceholders) { if (-not $Template.Contains($ph)) { $hasAllOverride = $false; break } }
        if ($hasAllOverride) { $resolved = $Template }
    }
    if ($null -eq $resolved) {
        foreach ($candidatePath in @(
            (Join-Path (Get-BatonHome) 'prompts/conductor-planner.txt'),
            (Join-Path $PSScriptRoot '../prompts/conductor-planner.txt')
        )) {
            if (-not (Test-Path $candidatePath)) { continue }
            $candidate = $null
            try { $candidate = Get-Content -Raw -LiteralPath $candidatePath -ErrorAction Stop } catch { continue }
            if ([string]::IsNullOrEmpty($candidate)) { continue }
            $hasAll = $true
            foreach ($ph in $requiredPlaceholders) { if (-not $candidate.Contains($ph)) { $hasAll = $false; break } }
            if ($hasAll) { $resolved = $candidate; break }
        }
    }
    if ($null -eq $resolved) { $resolved = $script:DefaultPlannerPrompt }

    # Single-pass token substitution: never rescan already-substituted content
    # (a directory literally named {{Goal}} must not expand to the goal text).
    $schemaVal = $schema; $eviVal = $evi; $goalVal = $Goal
    return [regex]::Replace($resolved, '\{\{(schema|evi|Goal)\}\}', {
        param($m)
        switch ($m.Groups[1].Value) {
            'schema' { return $schemaVal }
            'evi'    { return $eviVal }
            'Goal'   { return $goalVal }
            default  { return $m.Value }
        }
    })
}

function Invoke-PlanPhase {
    <# Route the goal to a reasoning-capable worker, parse its task DAG. Returns a
       plan hashtable or $null. -Dispatcher injects for tests; real path uses Invoke-Fleet. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string]$RunId,
        $BudgetCap = $null,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string[]]$RegistryLines = @(),
        [scriptblock]$Dispatcher,
        [string]$RunDir,
        [scriptblock]$ShadowResolver,
        [string]$RepoPath,
        # How many reasoning candidates planning may try before giving up.
        [int]$MaxPlannerAttempts = 3
    )
    $dispatch = {
        param($cand, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $cand $prompt) }
        return Invoke-Fleet -Name $cand.name -Prompt $prompt -Path $FleetPath -NoJournal
    }
    $cands = Select-Capability -Capability reasoning -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) { return $null }
    # Slice B: shadow A/B assignment (fail-open; no RunDir = no shadow).
    $shadowTemplate = $null
    if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
        $sv = $null
        try { $sv = if ($ShadowResolver) { & $ShadowResolver } else { Resolve-ShadowVariant } } catch { $sv = $null }
        if ($sv -and $sv.shadow) {
            if ($sv.role -eq 'challenger') { $shadowTemplate = [string]$sv.template }
            try {
                @{ variant_id = [string]$sv.variant_id; role = [string]$sv.role
                   challenger_id = [string]$sv.challenger_id
                   assigned = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } |
                    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDir 'shadow.json') -Encoding utf8NoBOM
                $vsOther = if ($sv.role -eq 'challenger') { 'champion' } else { "challenger $($sv.challenger_id)" }
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Message "prompt variant $($sv.variant_id) ($($sv.role)) — live A/B vs $vsOther")
            } catch { $shadowTemplate = $null }
        }
    }
    $promptParams = @{ Goal = $Goal; RegistryLines = $RegistryLines }
    if ($shadowTemplate) { $promptParams.Template = $shadowTemplate }
    if (-not [string]::IsNullOrWhiteSpace($RepoPath)) { $promptParams.RepoPath = $RepoPath }
    if (-not [string]::IsNullOrWhiteSpace($FleetPath)) { $promptParams.FleetPath = $FleetPath }
    $prompt = Build-PlannerPrompt @promptParams
    # Planning used to be one shot at $cands[0]: a failed dispatch or unparseable
    # answer ended the whole run with plan-failed, even with viable candidates
    # sitting right there in the list. That made the FIRST-RANKED provider a hard
    # dependency of every run — on a box where economy ranking puts a Claude row
    # first, `baton go` could not start from a shell with no Claude auth, despite
    # the engine itself being vendor-neutral.
    #
    # Bounded on purpose: candidates are cost-ordered, so walking a few is cheap,
    # but an unbounded walk could fan a broken prompt across the paid fleet.
    #
    # MERGE NOTE (#186 + #189): both branches fixed this independently — #186 with a
    # hand-rolled bounded loop, #189 by routing through the shared walk helper. Kept
    # the shared helper (one failover implementation for every model-calling phase,
    # which is the point of #code-factory) and passed #186's bound through as
    # -MaxAttempts, so neither the consistency nor the safety property was dropped.
    # Events use the 'provider-failover' kind other phases use, not 'plan'.
    # Invoke-CapabilityFailover treats a NONPOSITIVE -MaxAttempts as "no limit", but the
    # bounded loop this replaced treated MaxPlannerAttempts=0 as "no attempts at all"
    # (`if ($attempts -ge $MaxPlannerAttempts) { break }` fired immediately). Passing 0
    # straight through would silently invert the safest possible setting into the most
    # expensive one -- walking the entire roster. Preserve the original meaning.
    if ($MaxPlannerAttempts -le 0) { return $null }
    $walk = Invoke-CapabilityFailover -Candidates ([object[]]$cands) -Phase 'planner' `
        -MaxAttempts $MaxPlannerAttempts `
        -Attempt { param($c) & $dispatch $c $prompt } `
        -IsUsable { param($r)
            if (-not (Test-FailoverResultUsable -Result $r)) { return $false }
            return ($null -ne (ConvertTo-PlanObject -RawStdout ([string]$r.stdout)))
        } `
        -OnHop {
            param($from, $to, $why)
            # Name the failure: a silent fallback would hide a planner that is broken
            # for everyone rather than merely unavailable to this shell.
            if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'provider-failover' -Level 'warn' -Message "planner: $from -> $to ($why)")
            }
        }
    if (-not $walk.ok) {
        if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'provider-failover' -Level 'error' -Message ([string]$walk.why))
        }
        return $null
    }
    if ($walk.hops -gt 0 -and -not [string]::IsNullOrWhiteSpace($RunDir)) {
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'provider-failover' -Message ([string]$walk.why))
    }
    $res = $walk.result
    $plan = ConvertTo-PlanObject -RawStdout ([string]$res.stdout)
    if ($null -eq $plan) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
        $plan = Repair-PlanAllowedPaths -Plan $plan -RepoPath $RepoPath
    }
    try {
        $effPlan = Invoke-EfficiencyPlanAdvise -Plan $plan -RepoRoot $RepoPath
        if ($effPlan -and $effPlan.plan) { $plan = $effPlan.plan }
    } catch { }
    if ($RunId) { $plan.run_id = $RunId }
    $plan.goal = $Goal
    if ($null -ne $BudgetCap) { $plan.budget_cap = [double]$BudgetCap }
    return $plan
}

function Invoke-TaskViaFleet {
    <# Default executor when no -Spawner is injected: route the task's capability
       through the fleet (a model call). Non-destructive by construction — it never
       touches the repo; real code/merge execution is wired by a box via -Spawner. #>
    param(
        [Parameter(Mandatory)]$Task,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$RepoPath,
        [string]$RunDir,
        [scriptblock]$Dispatcher
    )
    $cap = if ($Task.capability) { $Task.capability } else { 'reasoning' }
    $cands = Select-Capability -Capability $cap -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) {
        return @{ ok = $false; spend = 0.0; chose = ''; why = "no candidate for capability '$cap'"; alternatives = @() }
    }
    $prompt = "Task: $($Task.desc)"
    try {
        $effArgs = @{ Task = $Task }
        if (-not [string]::IsNullOrWhiteSpace($RepoPath)) { $effArgs.RepoPath = $RepoPath }
        if (-not [string]::IsNullOrWhiteSpace($RunDir)) { $effArgs.RunDir = $RunDir }
        $eff = Invoke-EfficiencyAdvise @effArgs
        if ($eff -and $eff.prompt) { $prompt = [string]$eff.prompt }
        if ($eff -and $eff.cheaper_tier -and $Task.PSObject.Properties['est_cost_tier']) {
            # Advise only — never raise a tier, never block.
            $cur = [string]$Task.est_cost_tier
            if ($cur -eq 'paid' -and [string]$eff.cheaper_tier -eq 'free') {
                $Task.est_cost_tier = 'free'
            }
        }
    } catch { }
    # Code factory (#code-factory): the non-agentic labor phase walks the cost-ordered
    # roster too. This executor never touches the repo (see the summary above), so a
    # failed candidate can be retried on the next-cheapest peer with no cleanup.
    $walk = Invoke-CapabilityFailover -Candidates ([object[]]$cands) -Phase "labor ($cap)" `
        -Attempt {
            param($c)
            if ($Dispatcher) { return (& $Dispatcher $c $prompt) }
            $vramClaim = $null
            if ([string]$c.cost_tier -eq 'local') {
                try {
                    $prof = Resolve-VramProfileForProvider -Provider $c
                    $vramClaim = Request-VramClaim -Profile $prof -Model ([string]$c.name) `
                        -RunId ("labor-" + [string]$Task.id)
                    if (-not $vramClaim.ok) {
                        return @{ stdout = ''; stderr = [string]$vramClaim.reason; exit_code = -1; duration_s = 0 }
                    }
                } catch { }
            }
            return Invoke-Fleet -Name $c.name -Prompt $prompt -Path $FleetPath -NoJournal
        }
    $alts = @($cands | Where-Object { $null -ne $_ -and [string]$_.name -ne [string]$walk.chose } | ForEach-Object { [string]$_.name })
    if (-not $walk.ok) {
        # Every eligible provider is out — that is a labor-AVAILABILITY halt (#124),
        # not an implementation defect, so report.md says so via the Labor section.
        return @{
            ok = $false; spend = 0.0; chose = ([string]@($walk.attempts)[-1]); why = [string]$walk.why
            alternatives = $alts; labor = 'unavailable'; exclusions = @($walk.exclusions)
        }
    }
    return @{ ok = $true; spend = 0.0; chose = [string]$walk.chose; why = [string]$walk.why; alternatives = $alts }
}

function Complete-Run {
    <# Render report.md (+ optional ## Acceptance) and return the terminal status hashtable.
       -Gate (untyped: ordered dict or hashtable) writes acceptance.json + appends the section. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$Plan,
        [array]$Decisions = @(),
        [double]$Spend = 0.0,
        [string]$Status = 'completed',
        [string]$PendingTaskId = '',
        $Gate = $null,
        [object[]]$TaskCosts = @(),
        # #124: the failing spawner result when the halt was labor availability —
        # renders the '## Labor' section so report.md names the real cause.
        $LaborFailure = $null
    )
    $report = Format-RunReport -Plan $Plan -Decisions @($Decisions) -Spend $Spend -Status $Status -PendingTaskId $PendingTaskId
    if ($Gate) {
        $report = $report + "`n`n" + (Format-AcceptanceSection -Gate $Gate)
        ($Gate | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance.json') -Encoding utf8NoBOM
    }
    $verSection = Format-VerificationSection -RunDir $RunDir -Plan $Plan
    if ($verSection) {
        $report = $report + "`n`n" + $verSection
    }
    if ($LaborFailure) {
        $report = $report + "`n`n" + (Format-LaborSection -Result $LaborFailure)
    }
    # Effective cost (slice 1): only when a gate produced a verdict (a quality signal).
    $effectiveCost = $null
    $realizedRunCost = $null
    if ($Gate -and $Gate.verdict) {
        $quality   = Get-QualityScalar -Verdict ([string]$Gate.verdict) -Counts $Gate.counts
        $runCost   = Get-RunCost -Tasks @($TaskCosts) -CostResolver { param($t) Get-RealizedTaskCost -Task $t -RunDir $RunDir }
        $realizedRunCost = [double]$runCost.cost
        $effective = Get-EffectiveCost -Cost $runCost.cost -Quality $quality
        $breakdown = Get-WorkerBreakdown -Tasks @($TaskCosts)
        $record = New-EffectiveCostRecord -RunId $Plan.run_id -Verdict ([string]$Gate.verdict) `
            -Quality $quality -Cost $runCost.cost -CostBasis $runCost.basis -Attempts $runCost.attempts `
            -EffectiveCost $effective -Workers $breakdown
        $report = $report + "`n`n" + (Format-EffectiveCostSection -Record $record)
        ($record | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'effective-cost.json') -Encoding utf8NoBOM
        $effectiveCost = $effective
    }
    Set-Content -LiteralPath (Join-Path $RunDir 'report.md') -Value $report -Encoding utf8NoBOM

    # -- Slice B: live shadow A/B accrual + auto-retire. Strictly after the
    # user-facing report; fail-open — a pool problem never breaks the run. --
    try {
        $shadowPath = Join-Path $RunDir 'shadow.json'
        if (Test-Path $shadowPath) {
            $assign = Get-Content -Raw -LiteralPath $shadowPath | ConvertFrom-Json -AsHashtable
            $poolLoaded = Get-PromptPool
            if (($null -ne $assign) -and $assign.variant_id -and $poolLoaded.ok) {
                $livePool = $poolLoaded.pool
                if ($null -eq $realizedRunCost) {
                    # Ungated run: no effective-cost pass ran, meter here — dollars are real either way.
                    $rc = Get-RunCost -Tasks @($TaskCosts) -CostResolver { param($t) Get-RealizedTaskCost -Task $t -RunDir $RunDir }
                    $realizedRunCost = [double]$rc.cost
                }
                $accrue = @{ Pool = $livePool; VariantId = [string]$assign.variant_id; CostUsd = $realizedRunCost }
                if ($Gate -and $Gate.verdict -and (([string]$Gate.verdict) -in @('accept', 'polish', 'reject'))) {
                    $accrue.Verdict = [string]$Gate.verdict
                }
                [void](Add-LiveRunResult @accrue)
                # v1.7.1: judge the challenger this run was ASSIGNED (shadow.json),
                # not whoever selection would pick now — a mid-run evolution must
                # not misattribute the verdict.
                $sv = Get-ShadowVerdict -Pool $livePool -ChallengerId ([string]$assign.challenger_id)
                if ($sv.state -in @('retire', 'promote')) {
                    $challCpa = if ($null -ne $sv.challenger_cpa) { '{0:n4}' -f [double]$sv.challenger_cpa } else { 'n/a (0 accepts)' }
                    $champCpa = if ($null -ne $sv.champion_cpa) { '{0:n4}' -f [double]$sv.champion_cpa } else { 'n/a (0 accepts)' }
                    if ($sv.state -eq 'retire') {
                        $why = "live A/B loss vs $($sv.champion_id): cost_per_accept $challCpa vs $champCpa over $($sv.challenger_gated)/$($sv.champion_gated) gated runs"
                        [void](Set-CandidateRetired -Pool $livePool -Id ([string]$sv.challenger_id) -Reason $why -By ([string]$sv.champion_id))
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Level 'warn' -Message "challenger $($sv.challenger_id) auto-retired: $why")
                    } else {
                        # v1.7.1: one nudge per candidate — the --pool report still
                        # shows the live verdict on every invocation.
                        $challNudge = @($livePool.candidates | Where-Object { $_.id -eq $sv.challenger_id })[0]
                        if ($null -eq $challNudge.promote_recommended_at) {
                            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Message "challenger $($sv.challenger_id) is winning in dollars (cost_per_accept $challCpa vs $champCpa) — promote via /baton:optimize-prompt --apply")
                            $challNudge.promote_recommended_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    }
                }
                Save-PromptPool -Pool $livePool
            }
        }
    } catch {
        try { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Level 'warn' -Message "shadow accrual failed (run unaffected): $($_.Exception.Message)") } catch { }
    }

    return @{ status = $Status; run_id = $Plan.run_id; run_dir = $RunDir; spend = $Spend; pending_task_id = $PendingTaskId; report = $report; acceptance = $Gate; effective_cost = $effectiveCost }
}

function Invoke-PlanRevise {
    <# One-shot revise pass (d080, Slice 2): re-plan $Goal with the prior plan and the
       peer-review revise brief appended, parse via ConvertTo-PlanObject, and return the
       revised plan — overwriting plan.json on success. Fail-open by construction: a
       missing reviewing worker, a non-zero exit, an unparseable reply, OR a throw from
       the dispatch all return the ORIGINAL plan ($Run) unchanged and log the fall-back.
       Never a second attempt, never a throw. Mirrors Invoke-PlanPhase's reasoning
       routing and its -Dispatcher test seam so hermetic tests can stub the worker. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [Parameter(Mandatory)][string]$PlanJson,
        [Parameter(Mandatory)][string]$ReviseBrief,
        [Parameter(Mandatory)][hashtable]$Run,
        [string]$RunDir,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string[]]$RegistryLines = @(),
        [scriptblock]$Dispatcher,
        [string]$RepoPath
    )
    $dispatch = {
        param($cand, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $cand $prompt) }
        return Invoke-Fleet -Name $cand.name -Prompt $prompt -Path $FleetPath -NoJournal
    }
    $failMsg = 'revise pass failed to parse — proceeding with the original plan'
    # Widen fail-open (codex): ALL revise-pass work — roster resolution (Select-Capability
    # can throw on a malformed fleet/tools file), prompt build, dispatch, and parse — runs
    # inside one try. ANY failure returns the ORIGINAL plan ($Run) with the fail-open event.
    # A missing worker still short-circuits inside the try with the same message. No behavior
    # change on the success path.
    $revised = $null
    try {
        $cands = Select-Capability -Capability reasoning -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
        if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) {
            if ($RunDir) { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message $failMsg) }
            return $Run
        }
        # Reuse the standard planner prompt, then append the prior plan + the brief. Literal
        # concatenation only — $PlanJson/$ReviseBrief are untrusted; never -replace (a '$1'/'$&'
        # in the text would be read as a regex backreference and corrupt the prompt).
        $promptBuild = @{ Goal = $Goal; RegistryLines = $RegistryLines }
        if (-not [string]::IsNullOrWhiteSpace($RepoPath)) { $promptBuild.RepoPath = $RepoPath }
        if (-not [string]::IsNullOrWhiteSpace($FleetPath)) { $promptBuild.FleetPath = $FleetPath }
        $base = Build-PlannerPrompt @promptBuild
        $prompt = $base + "`n`n## Prior plan (JSON)`n" + $PlanJson +
                  "`n`n## Peer review findings — revise the plan to address these`n" + $ReviseBrief +
                  "`n`nEmit the FULL revised plan as JSON in the same schema. Address every finding you can without expanding scope."
        # NO provider failover here, deliberately. The revise pass is a documented
        # ONE-SHOT (see the summary above) and it already fails open to the original
        # plan, so a capped provider here cannot stall a run — the code-factory
        # guarantee is not at stake, and walking the roster would burn a second
        # planner-sized call to buy nothing.
        $res = & $dispatch $cands[0] $prompt
        if ([int]$res.exit_code -eq 0) { $revised = ConvertTo-PlanObject -RawStdout ([string]$res.stdout) }
        if ($null -ne $revised -and -not [string]::IsNullOrWhiteSpace($RepoPath)) {
            $revised = Repair-PlanAllowedPaths -Plan $revised -RepoPath $RepoPath
        }
    } catch {
        Write-Debug "revise pass failed: $($_.Exception.Message)"
    }
    if ($null -eq $revised) {
        if ($RunDir) { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message $failMsg) }
        return $Run
    }
    # Carry the run identity forward from the original plan (the revised reply may have
    # invented its own run_id/goal/budget_cap — the run's own values win).
    $revised.run_id = $Run.run_id
    $revised.goal = $Goal
    $revised.budget_cap = $Run.budget_cap
    if ($RunDir) {
        ($revised | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'plan.json') -Encoding utf8NoBOM
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message 'plan revised once per peer review — walking the revised plan (no re-gate)')
    }
    return $revised
}

function Invoke-Conductor {
    <# Full-auto engine: plan, then walk the DAG under the two interrupt guards,
       logging events/decisions, and render a report. -Planner/-Spawner/-Dispatcher
       inject for tests; real path uses Invoke-PlanPhase + Invoke-TaskViaFleet. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string]$RunDir,
        $BudgetCap = $null,
        [double]$PaidPerCall = 0.05,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Planner,
        [scriptblock]$Spawner,
        [scriptblock]$Dispatcher,
        [string]$GateArtifact,
        [string]$GateDiff,
        [scriptblock]$Gater,
        [scriptblock]$DiffProvider,
        [switch]$PlanGate,
        [switch]$PlanGateFailLoud,
        [string[]]$PlanReviewers,
        [bool]$PlanRevise = $true,
        [scriptblock]$PlanGateDispatcher,
        [switch]$AcceptanceGate,
        [switch]$AcceptancePanel,
        [switch]$AcceptanceFailLoud,
        [switch]$Verify,
        [scriptblock]$VerifyPreflight,
        [switch]$NormalizeMissingStakes,
        [switch]$RequireTaskStakes,
        [ValidateSet('low','standard','high')][string]$StakesOverride,
        [string]$RepoPath,
        # Optional execute worktree: used by acceptance-rework scope check (#128 review).
        # When set, post-rework labor is diffed via git (same mechanism as the verifier)
        # against the UNION of plan tasks' allowed_paths before re-paneling.
        [string]$Worktree = ''
    )
    if (-not $RunDir) { $RunDir = Initialize-RunDir }
    else { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }
    $runId = Split-Path $RunDir -Leaf

    # 1. Plan phase.
    $plan = if ($Planner) { & $Planner $Goal }
            else {
                $planArgs = @{
                    Goal = $Goal; RunId = $runId; BudgetCap = $BudgetCap; MaxCostTier = $MaxCostTier
                    FleetPath = $FleetPath; ToolsPath = $ToolsPath; Dispatcher = $Dispatcher; RunDir = $RunDir
                }
                if (-not [string]::IsNullOrWhiteSpace($RepoPath)) { $planArgs.RepoPath = $RepoPath }
                Invoke-PlanPhase @planArgs
            }
    if ($null -eq $plan) {
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'error' -Level 'error' -Message 'planning failed')
        $empty = @{ run_id = $runId; goal = $Goal; budget_cap = $BudgetCap; tasks = @() }
        return (Complete-Run -RunDir $RunDir -Plan $empty -Status 'plan-failed')
    }
    $plan.run_id = $runId
    # Stakes policy (d086 / #101):
    #   -StakesOverride            → force every task (operator --stakes)
    #   -NormalizeMissingStakes    → opt-in soft path (legacy / non-execute aging)
    #   -RequireTaskStakes         → hard-fail on missing (default --execute)
    #   none of the above          → leave plan alone (library / plan-only)
    $missingStakesPolicyMessage = 'missing stakes normalized to standard; applied policy: depth med, economy routing, capped by run and task cost tiers'
    $hasStakesOverride = $PSBoundParameters.ContainsKey('StakesOverride')
    # Precedence when switches collide: StakesOverride > RequireTaskStakes > NormalizeMissingStakes > none.
    # -RequireTaskStakes is an explicit hard contract, so it wins over the soft -NormalizeMissingStakes.
    if ($hasStakesOverride -or ($NormalizeMissingStakes -and -not $RequireTaskStakes)) {
        $missingStakes = 0
        foreach ($plannedTask in @($plan.tasks)) {
            if ($hasStakesOverride) {
                $plannedTask | Add-Member -NotePropertyName stakes -NotePropertyValue $StakesOverride -Force
                $plannedTask | Add-Member -NotePropertyName stakes_basis -NotePropertyValue "operator override: --stakes $StakesOverride" -Force
            } elseif ([string]::IsNullOrWhiteSpace([string]$plannedTask.stakes)) {
                $plannedTask | Add-Member -NotePropertyName stakes -NotePropertyValue 'standard' -Force
                $plannedTask | Add-Member -NotePropertyName stakes_basis -NotePropertyValue 'legacy plan omitted stakes' -Force
                $missingStakes++
            } elseif ([string]$plannedTask.stakes_basis -eq 'legacy plan omitted stakes') {
                $missingStakes++
            }
            if ([string]$plannedTask.stakes -notin @('low','standard','high') -or
                [string]::IsNullOrWhiteSpace([string]$plannedTask.stakes_basis)) {
                $softInvalidMsg = "task $($plannedTask.id) has invalid stakes/stakes_basis"
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'policy' -Level 'error' -Message $softInvalidMsg)
                [Console]::Error.WriteLine($softInvalidMsg)
                return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
            }
        }
        if ($missingStakes -gt 0) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'policy' -Level 'warn' -Message "$missingStakes task(s) $missingStakesPolicyMessage")
        }
    } elseif ($RequireTaskStakes) {
        $missingStakeIds = [System.Collections.ArrayList]@()
        foreach ($plannedTask in @($plan.tasks)) {
            $taskStakes = [string]$plannedTask.stakes
            $taskBasis = [string]$plannedTask.stakes_basis
            if ([string]::IsNullOrWhiteSpace($taskStakes) -or $taskBasis -eq 'legacy plan omitted stakes') {
                [void]$missingStakeIds.Add([string]$plannedTask.id)
                continue
            }
            if ($taskStakes -notin @('low','standard','high') -or [string]::IsNullOrWhiteSpace($taskBasis)) {
                $invalidMsg = "task $($plannedTask.id) has invalid stakes/stakes_basis"
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'policy' -Level 'error' -Message $invalidMsg)
                [Console]::Error.WriteLine($invalidMsg)
                return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
            }
        }
        if ($missingStakeIds.Count -gt 0) {
            $idList = (@($missingStakeIds) -join ', ')
            $haltMsg = "PLAN-INVALID — task(s) missing stakes: $idList — add stakes and stakes_basis to each task, or pass --stakes <low|standard|high>, or -NormalizeMissingStakes"
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'policy' -Level 'error' -Message $haltMsg)
            [Console]::Error.WriteLine($haltMsg)
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
        }
    }
    ($plan | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'plan.json') -Encoding utf8NoBOM
    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'started' -Message "plan: $(@($plan.tasks).Count) tasks")

    # 1.5 Plan Gate (d080, Slice 2): policy-selected peer once-over BEFORE the walk.
    #     — a sibling of the post-work Acceptance Gate (d058), but it reviews the not-yet-run
    #     PLAN. Legacy calls remain advisory/fail-open; -PlanGateFailLoud turns missing
    #     evidence, infrastructure failure, and a failed required revise pass into
    #     plan-gate-degraded before any DAG labor.
    if ($PlanGate) {
        # The exact plan.json we just wrote is the artifact the reviewers see.
        $planJsonText = Get-Content -Raw -LiteralPath (Join-Path $RunDir 'plan.json')
        $pgRes = $null
        try {
            $pgRes = Invoke-PlanGate -Goal $Goal -PlanJson $planJsonText -Reviewers $PlanReviewers `
                -Dispatcher $PlanGateDispatcher -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath `
                -FailLoud:$PlanGateFailLoud
        } catch {
            # Standalone remains advisory. Execute fail-loud consumes the null below.
            if (-not $PlanGateFailLoud) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'warn' -Message "plan gate failed (fail-open, walking the plan as-is): $($_.Exception.Message)")
            }
            $pgRes = $null
        }
        if ($PlanGateFailLoud -and $null -eq $pgRes) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'error' -Message 'PLAN GATE DEGRADED — gate returned no usable result — no labor will run')
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-gate-degraded')
        }
        if ($null -ne $pgRes) {
            $pgJson = ConvertTo-Json -Depth 8 -InputObject $pgRes
            Set-Content -LiteralPath (Join-Path $RunDir 'plan-review.json') -Value $pgJson -Encoding utf8NoBOM
            $c = $pgRes.counts
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message "plan verdict: $($pgRes.verdict) — $($pgRes.reason) ($($c.critical) critical, $($c.important) important, $($c.minor) minor)")
            if ($PlanGateFailLoud -and ($pgRes.degraded -or $pgRes.fail_open)) {
                $pgReason = if ([string]::IsNullOrWhiteSpace([string]$pgRes.reason)) { 'gate returned a degraded result' } else { [string]$pgRes.reason }
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'error' -Message "PLAN GATE DEGRADED — $pgReason — no labor will run")
                return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-gate-degraded')
            }
            $verdict = [string]$pgRes.verdict
            if ($verdict -ne 'accept') {
                Set-Content -LiteralPath (Join-Path $RunDir 'revise_brief.md') -Value ([string]$pgRes.revise_brief) -Encoding utf8NoBOM
            }
            if ($verdict -eq 'reject') {
                # Hard stop: report the rejection, then exit clean via the same Complete-Run
                # path plan-failed uses. No walk, no worktree, no spend.
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'warn' -Message "plan rejected before the walk: $($pgRes.reason) — no worktree, no labor, no spend")
                return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-rejected')
            }
            elseif ($verdict -eq 'revise') {
                if ($PlanRevise) {
                    # One revise pass, then walk whichever plan survives (no re-gate, Slice 2).
                    $priorPlan = $plan
                    $reviseArgs = @{
                        Goal = $Goal; PlanJson = $planJsonText; ReviseBrief = [string]$pgRes.revise_brief
                        Run = $plan; RunDir = $RunDir; MaxCostTier = $MaxCostTier
                        FleetPath = $FleetPath; ToolsPath = $ToolsPath; Dispatcher = $Dispatcher
                    }
                    if (-not [string]::IsNullOrWhiteSpace($RepoPath)) { $reviseArgs.RepoPath = $RepoPath }
                    $revisedPlan = Invoke-PlanRevise @reviseArgs
                    $revisionApplied = -not [object]::ReferenceEquals($priorPlan, $revisedPlan)
                    if ($PlanGateFailLoud -and -not $revisionApplied) {
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'error' -Message 'PLAN GATE DEGRADED — required revise pass failed — no labor will run')
                        return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-gate-degraded')
                    }
                    $plan = $revisedPlan
                    $plan.run_id = $runId
                    if ($hasStakesOverride) {
                        foreach ($revisedTask in @($plan.tasks)) {
                            $revisedTask | Add-Member -NotePropertyName stakes -NotePropertyValue $StakesOverride -Force
                            $revisedTask | Add-Member -NotePropertyName stakes_basis -NotePropertyValue "operator override: --stakes $StakesOverride" -Force
                        }
                        ($plan | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'plan.json') -Encoding utf8NoBOM
                    } elseif ($revisionApplied -and $NormalizeMissingStakes) {
                        $revisedMissingStakes = @($plan.tasks | Where-Object { [string]$_.stakes_basis -eq 'legacy plan omitted stakes' }).Count
                        if ($revisedMissingStakes -gt 0) {
                            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'policy' -Level 'warn' -Message "$revisedMissingStakes task(s) $missingStakesPolicyMessage")
                        }
                    } elseif ($revisionApplied -and $RequireTaskStakes) {
                        foreach ($revisedTask in @($plan.tasks)) {
                            $revTaskStakes = [string]$revisedTask.stakes
                            $revTaskBasis = [string]$revisedTask.stakes_basis
                            if ([string]::IsNullOrWhiteSpace($revTaskStakes) -or $revTaskBasis -eq 'legacy plan omitted stakes') {
                                continue
                            }
                            if ($revTaskStakes -notin @('low','standard','high') -or [string]::IsNullOrWhiteSpace($revTaskBasis)) {
                                $revInvalidMsg = "task $($revisedTask.id) has invalid stakes/stakes_basis"
                                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'policy' -Level 'error' -Message $revInvalidMsg)
                                [Console]::Error.WriteLine($revInvalidMsg)
                                return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
                            }
                        }
                        $revisedMissingIds = @($plan.tasks | Where-Object {
                            [string]::IsNullOrWhiteSpace([string]$_.stakes) -or
                            [string]$_.stakes_basis -eq 'legacy plan omitted stakes'
                        } | ForEach-Object { [string]$_.id })
                        if ($revisedMissingIds.Count -gt 0) {
                            $revIdList = ($revisedMissingIds -join ', ')
                            $revHaltMsg = "PLAN-INVALID — task(s) missing stakes: $revIdList — add stakes and stakes_basis to each task, or pass --stakes <low|standard|high>, or -NormalizeMissingStakes"
                            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'policy' -Level 'error' -Message $revHaltMsg)
                            [Console]::Error.WriteLine($revHaltMsg)
                            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
                        }
                    }
                } else {
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message 'revise recommended, auto-revise disabled — proceeding with the original plan')
                }
            }
        }
    }

    # 1.7 Verification preflight (d082 V2): OPT-IN. Freeze every referenced verify
    #     profile from the base revision and validate it BEFORE the walk — an unknown,
    #     missing, or lint-failing contract fails the plan closed (plan-invalid) before
    #     any labor spend. Fail-CLOSED (unlike the advisory gates): a task that demands
    #     verification cannot run without a resolvable oracle. Without -Verify this block
    #     is skipped entirely (default path unchanged).
    if ($Verify -and $VerifyPreflight) {
        $pf = $null
        try { $pf = & $VerifyPreflight $plan }
        catch {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'verification' -Level 'error' -Message "verification preflight threw: $($_.Exception.Message)")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
        }
        if ($null -ne $pf -and -not $pf.ok) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'verification' -Level 'error' -Message "verification preflight failed: $($pf.reason) — no walk, no spend")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
        }
    }

    # 2. Order the DAG.
    try { $order = Resolve-TaskOrder -Tasks @($plan.tasks) }
    catch {
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'error' -Level 'error' -Message $_.Exception.Message)
        return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
    }

    # 3. Guarded walk.
    $spend = 0.0
    $decisions = [System.Collections.ArrayList]@()
    $taskCosts = [System.Collections.ArrayList]@()
    foreach ($task in $order) {
        $est = Get-TaskCostEstimate -Tier $task.est_cost_tier -PaidPerCall $PaidPerCall
        if (Test-BudgetExceeded -CumulativeSpend $spend -TaskEstimate $est -BudgetCap $BudgetCap) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt' -Level 'warn' -Message "budget: would cross cap at $($task.id)")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-budget' -PendingTaskId $task.id)
        }
        if (Test-TaskDestructive -Task $task) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt' -Level 'warn' -Message "destructive: $($task.id) is reversible:false")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-destructive' -PendingTaskId $task.id)
        }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'started' -Message $task.desc)
        # Verification (d082 V2): announce the sub-lifecycle before labor so the six-kind
        # event contract is literal (review M1). Only for a -Verify run on a task that
        # actually carries a frozen contract — an unprofiled task stays silent here.
        if ($Verify -and [string]$task.verify_profile) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-verification-started' -Message "verifying: $($task.verify_profile)")
        }
        $fleetArgs = @{
            Task = $task; FleetPath = $FleetPath; ToolsPath = $ToolsPath
            MaxCostTier = $MaxCostTier; Dispatcher = $Dispatcher
        }
        if (-not [string]::IsNullOrWhiteSpace($RepoPath)) { $fleetArgs.RepoPath = $RepoPath }
        if (-not [string]::IsNullOrWhiteSpace($RunDir)) { $fleetArgs.RunDir = $RunDir }
        $r = if ($Spawner) { & $Spawner $task }
             else { Invoke-TaskViaFleet @fleetArgs }
        $tspend = if ($null -ne $r.spend) { [double]$r.spend } else { $est }
        $spend += $tspend
        if ($r.chose) {
            $decisionArgs = @{
                TaskId = $task.id; Chose = [string]$r.chose; Alternatives = @($r.alternatives)
                Why = [string]$r.why; CostTier = $task.est_cost_tier
            }
            $policyFields = [ordered]@{
                Stakes = 'stakes'; StakesBasis = 'stakes_basis'; DepthTier = 'depth_tier'
                DepthApplied = 'depth_applied'; SelectionMode = 'selection_mode'
                TierCap = 'tier_cap'; SelectedCostTier = 'selected_cost_tier'
            }
            foreach ($parameterName in $policyFields.Keys) {
                $propertyName = $policyFields[$parameterName]
                $hasField = if ($r -is [System.Collections.IDictionary]) {
                    $r.Contains($propertyName)
                } else {
                    $null -ne $r.PSObject.Properties[$propertyName]
                }
                if ($hasField) { $decisionArgs[$parameterName] = $r.$propertyName }
            }
            $dec = New-RunDecision @decisionArgs
            Add-RunDecision -RunDir $RunDir -Decision $dec
            [void]$decisions.Add($dec)
        }
        # Numerator is the cost-tier ESTIMATE (basis='estimate'), matching the budget
        # guard and the record's label — realized spend ($tspend) is a placeholder
        # (0.0) today; realized cost arrives later via Get-RunCost's -CostResolver seam.
        [void]$taskCosts.Add(@{ id = $task.id; worker = ([string]$r.chose); cost = $est })
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'spent' -Message ("{0:0.00}" -f $tspend))
        # Verification (d082 V2): the verifying spawner attaches a `verification`
        # result and/or an `unverified` mark to $r. Emit the legible event trail and
        # map a verification failure to its own terminal status. When -Verify is off
        # or the task carried no contract, $r has neither key and this is inert.
        if ($Verify -and $r.unverified) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-unverified' -Message "no verification contract — proceeding unverified")
        }
        if ($Verify -and $r.verification) {
            $v = $r.verification
            # Engine-owned rework journal (#128 slice 2): task-rework-started/-passed/-failed
            # + one decisions.jsonl row per cycle naming the evidence file path (not content).
            # Compat: stub spawners that only set retried=$true (no reworks[]) still emit one cycle.
            $reworkRows = @()
            if ($null -ne $v.reworks) { $reworkRows = @($v.reworks) }
            elseif ($v.retried) {
                $reworkOutcome = if ([string]$v.verdict -eq 'pass') { 'passed' } else { 'failed' }
                $reworkRows = @(@{
                    cycle = 1; evidence_path = ''; outcome = $reworkOutcome
                    failure_category = [string]$v.first_failure_category
                })
            }
            foreach ($rw in $reworkRows) {
                $cyc = if ($null -ne $rw.cycle) { [int]$rw.cycle } else { 1 }
                $evid = [string]$rw.evidence_path
                $trig = if ($evid) { $evid } else { [string]$v.first_failure_category }
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-rework-started' -Message "rework cycle $cyc — evidence: $trig")
                if ([string]$rw.outcome -eq 'passed') {
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-rework-passed' -Message "rework cycle $cyc passed")
                } else {
                    $failCat = if ($rw.failure_category) { [string]$rw.failure_category } else { [string]$v.failure_category }
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-rework-failed' -Level 'warn' -Message "rework cycle $cyc failed ($failCat)")
                }
                if ($evid) {
                    $rwDec = New-RunDecision -TaskId $task.id -Chose 'rework' -Alternatives @('halt', 'continue-without-rework') -Why "evidence: $evid"
                    Add-RunDecision -RunDir $RunDir -Decision $rwDec
                    [void]$decisions.Add($rwDec)
                }
            }
            if ([string]$v.verdict -eq 'pass') {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-verification-passed' -Message "verified (grade: $($v.grade)) — $($v.proves)")
            }
            elseif ([string]$v.failure_category -in @('scope-violation','protected-path-mutated')) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-scope-violation' -Level 'warn' -Message "scope/oracle violation ($($v.failure_category)) — fail-closed, no rework")
            }
            else {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-verification-failed' -Level 'warn' -Message "verification failed ($($v.failure_category))")
            }
        }
        # #124: a labor-availability halt gets its own event + terminal status so the
        # run never reads as a verification/implementation defect. The spawner sets
        # labor='unavailable' only when availability (lockout/hold/no-peer) — not
        # tier/config — emptied the pool.
        $laborUnavailable = (-not $r.ok) -and ([string]$r.labor -eq 'unavailable')
        if ($laborUnavailable) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'worker-selection-failed' -Level 'error' -Message ([string]$r.why))
        }
        $kind = if ($r.ok) { 'finished' } else { 'error' }
        # A failing result's why is the diagnostic (e.g. the zero-candidate remedy, #135) —
        # journal it; the operator already has the desc from this task's 'started' event.
        $termMsg = if (-not $r.ok -and -not [string]::IsNullOrWhiteSpace([string]$r.why)) { [string]$r.why } else { $task.desc }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind $kind -Message $termMsg)
        if (-not $r.ok) {
            $failStatus = if ($laborUnavailable) { 'labor-unavailable' }
                          elseif ($Verify -and $r.verification -and [string]$r.verification.verdict -ne 'pass') { 'verification-failed' } else { 'failed' }
            $crArgs = @{ RunDir = $RunDir; Plan = $plan; Decisions = $decisions; Spend = $spend; Status = $failStatus; PendingTaskId = $task.id }
            if ($laborUnavailable) { $crArgs.LaborFailure = $r }
            return (Complete-Run @crArgs)
        }
    }
    # 4. Acceptance phase (d058): runs after a successful walk when policy enables it.
    #    Legacy direct callers remain advisory; execute supplies panel + fail-loud.
    $gate = $null
    $finalStatus = 'completed'
    $acceptanceEnabled = if ($PSBoundParameters.ContainsKey('AcceptanceGate')) {
        [bool]$AcceptanceGate
    } else {
        $PSBoundParameters.ContainsKey('GateArtifact') -or
        $PSBoundParameters.ContainsKey('GateDiff') -or
        $null -ne $DiffProvider
    }
    # Slice 2 (d078): a -DiffProvider produces the walk's cumulative diff post-walk;
    # non-empty -> recorded to changes.diff and gated as the artifact. Absent, empty,
    # or throwing (fail-open) -> the existing -GateArtifact/-GateDiff path unchanged.
    $art = ''
    $diffProviderFailed = $false
    if ($DiffProvider) {
        $produced = ''
        try { $produced = [string](& $DiffProvider) }
        catch {
            $diffProviderFailed = $true
            # Under fail-loud this path degrades and halts (see $diffProviderFailed
            # consumer below); the event must say so, not narrate 'fail-open'.
            $dpFailLoud = $acceptanceEnabled -and $AcceptanceFailLoud
            $dpMsg = if ($dpFailLoud) { "diff provider failed (acceptance-degraded — run halts): $($_.Exception.Message)" }
                     else { "diff provider failed (fail-open): $($_.Exception.Message)" }
            $dpLevel = if ($dpFailLoud) { 'error' } else { 'warn' }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Level $dpLevel -Message $dpMsg)
        }
        if (-not [string]::IsNullOrWhiteSpace($produced)) {
            Set-Content -LiteralPath (Join-Path $RunDir 'changes.diff') -Value $produced -Encoding utf8NoBOM
            $art = $produced
        }
    }
    if ([string]::IsNullOrWhiteSpace($art)) { $art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff }
    if ($acceptanceEnabled -and -not [string]::IsNullOrWhiteSpace($art)) {
        $gateErr = $null
        try {
            $gate = if ($Gater) { & $Gater $art $plan.goal }
                    else {
                        $gateArgs = @{
                            Artifact = $art
                            Task = $plan.goal
                            MaxCostTier = $MaxCostTier
                            FleetPath = $FleetPath
                            ToolsPath = $ToolsPath
                        }
                        if ($AcceptancePanel) { $gateArgs['Panel'] = $true }
                        if ($AcceptanceFailLoud) { $gateArgs['FailLoud'] = $true }
                        Invoke-AcceptanceGate @gateArgs
                    }
        } catch { $gate = $null; $gateErr = $_.Exception.Message }
        # Round-2 C3: a LOST acceptance signal degrades the run status on BOTH paths.
        # -AcceptanceFailLoud decides whether the run HALTS; it must not decide whether
        # the run is allowed to call itself clean. Gating the degrade on fail-loud meant
        # d114's 'unreviewed' verdict died at the gate object and the run still reported
        # 'completed' — #190 gate 2, re-opened one layer up. Advisory still never blocks
        # the labor: the branch and worktree survive exactly as before.
        if ($null -eq $gate -or -not $gate.verdict) {
            $noVerdictBase = if ($gateErr) { "acceptance gate failed: $gateErr" } else { 'acceptance gate produced no verdict' }
            $msg = if ($AcceptanceFailLoud) { "$noVerdictBase (acceptance-degraded — run halts)" }
                   else { "$noVerdictBase (acceptance-degraded — advisory, run not blocked)" }
            $gateLevel = if ($AcceptanceFailLoud) { 'error' } else { 'warn' }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Level $gateLevel -Message $msg)
            $gate = $null
            $finalStatus = 'acceptance-degraded'
        } else {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Message "acceptance verdict: $($gate.verdict) — $($gate.reason)")
            # ORDER MATTERS. A reject is checked FIRST: a panel that lost a role but whose
            # surviving reviewers still found a critical has produced an actionable verdict,
            # and 'acceptance-degraded' would bury it. Both are non-clean, so this is not
            # about the fail-open — it is about which status tells the operator what to fix.
            # ('unreviewed' cannot collide: it means no usable review existed at all.)
            # 'unreviewed' (d114) is then checked alongside `degraded` rather than trusting
            # one of them: they are set together today, and a consumer keying on only one is
            # exactly the fail-open this finding is about.
            if ($gate.verdict -eq 'reject') { $finalStatus = 'rejected' }
            elseif ($gate.degraded -or $gate.verdict -eq 'unreviewed') { $finalStatus = 'acceptance-degraded' }
            elseif ($AcceptanceFailLoud -and $gate.verdict -eq 'polish') { $finalStatus = 'needs-polish' }
        }

        # Acceptance needs-polish rework (#128 slice 2, minimal seam): when fail-loud
        # polish carries findings AND a Spawner is available AND rework budget remains,
        # synthesize ONE evidence-only rework task (inherit last plan task's paths /
        # profile / stakes), re-run the panel. Fail again -> halt loudly; both verdicts
        # retained on the gate object + acceptance-prior.json. Counter is mechanical
        # (default max_rework=1). No Spawner -> skip (cannot labor).
        $accFindings = @()
        if ($null -ne $gate -and $null -ne $gate.findings) { $accFindings = @($gate.findings) }
        $accMaxRework = 1
        if (Get-Command Resolve-MaxRework -ErrorAction SilentlyContinue) {
            try { $accMaxRework = Resolve-MaxRework } catch { $accMaxRework = 1 }
        } elseif ($env:BATON_MAX_REWORK -and "$env:BATON_MAX_REWORK" -ne '') {
            try { $accMaxRework = [int]$env:BATON_MAX_REWORK } catch { $accMaxRework = 1 }
        }
        if (
            $null -ne $gate -and
            $AcceptanceFailLoud -and
            [string]$gate.verdict -eq 'polish' -and
            $accFindings.Count -gt 0 -and
            $null -ne $Spawner -and
            $accMaxRework -ge 1
        ) {
            $priorGate = $gate
            $accEvidence = Build-AcceptanceReworkEvidenceText -Gate $priorGate
            $accEvidPath = Join-Path $RunDir 'acceptance-rework-evidence-1.md'
            Set-Content -LiteralPath $accEvidPath -Value $accEvidence -Encoding utf8NoBOM
            # Inherit from the last plan task (run-level acceptance has no single owner).
            $src = $null
            $planTasks = @($plan.tasks)
            if ($planTasks.Count -gt 0) { $src = $planTasks[-1] }
            $accTask = [pscustomobject]@{
                id             = 'acceptance-rework-1'
                desc           = $accEvidence
                command        = ''
                capability     = if ($src -and $src.capability) { [string]$src.capability } else { 'code-gen' }
                depends_on     = @()
                est_cost_tier  = if ($src -and $src.est_cost_tier) { [string]$src.est_cost_tier } else { 'free' }
                reversible     = $true
                verify_profile = if ($src) { [string]$src.verify_profile } else { '' }
                allowed_paths  = if ($src -and $src.allowed_paths) { @($src.allowed_paths) } else { @() }
                stakes         = if ($src -and $src.stakes) { [string]$src.stakes } else { 'standard' }
                stakes_basis   = if ($src -and $src.stakes_basis) { [string]$src.stakes_basis } else { 'acceptance rework inheritance' }
            }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-started' -Message "acceptance needs-polish rework — evidence: $accEvidPath")
            $accRwDec = New-RunDecision -TaskId $accTask.id -Chose 'rework' -Alternatives @('halt', 'ship-as-polish') -Why "evidence: $accEvidPath"
            Add-RunDecision -RunDir $RunDir -Decision $accRwDec
            [void]$decisions.Add($accRwDec)

            # Pre-rework tree snapshot so we can scope-check ONLY the rework attempt's
            # diff (acceptance-rework has no frozen contract — without this the verifying
            # spawner falls through to UNVERIFIED and allowed_paths are cosmetic).
            $preAccTree = $null
            if (-not [string]::IsNullOrWhiteSpace($Worktree) -and (Test-Path -LiteralPath $Worktree -PathType Container)) {
                if (Get-Command Get-WorktreeTreeSha -ErrorAction SilentlyContinue) {
                    try { $preAccTree = Get-WorktreeTreeSha -Worktree $Worktree } catch { $preAccTree = $null }
                } else {
                    try {
                        & git -C $Worktree add -A 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            $preAccTree = [string](& git -C $Worktree write-tree 2>$null)
                            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($preAccTree)) { $preAccTree = $null }
                            else { $preAccTree = $preAccTree.Trim() }
                        }
                    } catch { $preAccTree = $null }
                }
            }

            $accRwResult = $null
            try { $accRwResult = & $Spawner $accTask } catch {
                $accRwResult = @{ ok = $false; spend = 0.0; why = $_.Exception.Message }
            }
            if ($null -ne $accRwResult.spend) { $spend += [double]$accRwResult.spend }

            # Scope gate BEFORE re-panel: rework labor must stay inside the UNION of
            # all plan tasks' allowed_paths (#125 exact + prefix matcher).
            $accScopeBlocked = $false
            $unionPaths = [System.Collections.Generic.List[string]]::new()
            foreach ($pt in $planTasks) {
                foreach ($ap in @($pt.allowed_paths)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$ap)) { [void]$unionPaths.Add([string]$ap) }
                }
            }
            if ($unionPaths.Count -eq 0) {
                # Scope was never enforced for this run — skip check, journal a one-line note.
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'gate' -Level 'info' -Message 'acceptance-rework scope check skipped — no allowed_paths declared on any plan task')
            } elseif (-not [string]::IsNullOrWhiteSpace($Worktree) -and $preAccTree -and (Test-Path -LiteralPath $Worktree -PathType Container)) {
                $postAccTree = $null
                if (Get-Command Get-WorktreeTreeSha -ErrorAction SilentlyContinue) {
                    try { $postAccTree = Get-WorktreeTreeSha -Worktree $Worktree } catch { $postAccTree = $null }
                } else {
                    try {
                        & git -C $Worktree add -A 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            $postAccTree = [string](& git -C $Worktree write-tree 2>$null)
                            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($postAccTree)) { $postAccTree = $null }
                            else { $postAccTree = $postAccTree.Trim() }
                        }
                    } catch { $postAccTree = $null }
                }
                if (-not $postAccTree) {
                    # Post-rework snapshot failed: the rework diff is uncheckable (same class
                    # as the pre-snapshot gap, #134) — an empty diff here would wave labor
                    # through unchecked. Fail closed, mirroring the uncheckable branch below.
                    $accScopeBlocked = $true
                    $msg = "acceptance-rework scope uncheckable — post-rework tree snapshot unavailable; re-panel skipped (fail-closed, union of plan allowed_paths declared)"
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'acceptance-rework-scope-violation' -Level 'error' -Message $msg)
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-failed' -Level 'error' -Message $msg)
                    $priorSnapPost = [ordered]@{
                        verdict = [string]$priorGate.verdict
                        reason = [string]$priorGate.reason
                        counts = $priorGate.counts
                        polish_brief = [string]$priorGate.polish_brief
                        findings = @($priorGate.findings)
                    }
                    ($priorSnapPost | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance-prior.json') -Encoding utf8NoBOM
                    $gate = $priorGate
                    $reworkMetaPost = @{
                        attempted = $true; evidence_path = $accEvidPath; outcome = 'failed'
                        reason = 'scope-uncheckable'
                    }
                    if ($gate -is [System.Collections.IDictionary]) {
                        $gate['prior_acceptance'] = $priorSnapPost
                        $gate['rework'] = $reworkMetaPost
                    } else {
                        $gate | Add-Member -NotePropertyName prior_acceptance -NotePropertyValue $priorSnapPost -Force
                        $gate | Add-Member -NotePropertyName rework -NotePropertyValue $reworkMetaPost -Force
                    }
                    $finalStatus = 'needs-polish'
                }
                if (-not $accScopeBlocked) { # post-snapshot guard: body keeps original indent for diff minimalism
                $accDiffFiles = @()
                if ($postAccTree -and $preAccTree -ne $postAccTree) {
                    $accDiffFiles = @(& git -C $Worktree diff --name-only $preAccTree $postAccTree 2>$null | Where-Object { $_ })
                }
                $scopeMatch = Test-DiffFilesInAllowedPaths -DiffFiles $accDiffFiles -AllowedPaths @($unionPaths)
                if (-not [bool]$scopeMatch.ok) {
                    $accScopeBlocked = $true
                    $offender = [string]$scopeMatch.first_offender
                    $scopeDiffPath = Join-Path $RunDir 'acceptance-rework-scope-diff.txt'
                    $diffBody = if ($accDiffFiles.Count -gt 0) { ($accDiffFiles -join "`n") } else { '(no files listed)' }
                    if ($postAccTree -and $preAccTree) {
                        try {
                            $unified = @(& git -C $Worktree diff $preAccTree $postAccTree 2>$null)
                            if ($unified) { $diffBody = ($unified -join "`n") }
                        } catch { }
                    }
                    Set-Content -LiteralPath $scopeDiffPath -Value $diffBody -Encoding utf8NoBOM
                    $msg = "acceptance-rework wrote out-of-scope path '$offender' (union of plan allowed_paths); re-panel skipped — diff retained at $scopeDiffPath"
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'acceptance-rework-scope-violation' -Level 'error' -Message $msg)
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-failed' -Level 'error' -Message $msg)
                    $priorSnapScope = [ordered]@{
                        verdict = [string]$priorGate.verdict
                        reason = [string]$priorGate.reason
                        counts = $priorGate.counts
                        polish_brief = [string]$priorGate.polish_brief
                        findings = @($priorGate.findings)
                    }
                    ($priorSnapScope | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance-prior.json') -Encoding utf8NoBOM
                    $gate = $priorGate
                    $reworkMeta = @{
                        attempted = $true; evidence_path = $accEvidPath; outcome = 'failed'
                        reason = 'acceptance-rework-scope-violation'; offender = $offender
                        scope_diff_path = $scopeDiffPath
                    }
                    if ($gate -is [System.Collections.IDictionary]) {
                        $gate['prior_acceptance'] = $priorSnapScope
                        $gate['rework'] = $reworkMeta
                    } else {
                        $gate | Add-Member -NotePropertyName prior_acceptance -NotePropertyValue $priorSnapScope -Force
                        $gate | Add-Member -NotePropertyName rework -NotePropertyValue $reworkMeta -Force
                    }
                    $finalStatus = 'needs-polish'
                }
                } # end post-snapshot guard (if -not $accScopeBlocked)
            } elseif (-not [string]::IsNullOrWhiteSpace($Worktree)) {
                # Scope was demanded (non-empty union, worktree provided) but the pre-rework
                # tree snapshot is unavailable (tree-sha failure or worktree vanished): the
                # rework diff cannot be scope-checked. Fail closed — never silently re-panel
                # unchecked labor (#134).
                $accScopeBlocked = $true
                $msg = "acceptance-rework scope uncheckable — pre-rework tree snapshot unavailable; re-panel skipped (fail-closed, union of plan allowed_paths declared)"
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'acceptance-rework-scope-violation' -Level 'error' -Message $msg)
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-failed' -Level 'error' -Message $msg)
                $priorSnapUncheck = [ordered]@{
                    verdict = [string]$priorGate.verdict
                    reason = [string]$priorGate.reason
                    counts = $priorGate.counts
                    polish_brief = [string]$priorGate.polish_brief
                    findings = @($priorGate.findings)
                }
                ($priorSnapUncheck | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance-prior.json') -Encoding utf8NoBOM
                $gate = $priorGate
                $reworkMetaUncheck = @{
                    attempted = $true; evidence_path = $accEvidPath; outcome = 'failed'
                    reason = 'scope-uncheckable'
                }
                if ($gate -is [System.Collections.IDictionary]) {
                    $gate['prior_acceptance'] = $priorSnapUncheck
                    $gate['rework'] = $reworkMetaUncheck
                } else {
                    $gate | Add-Member -NotePropertyName prior_acceptance -NotePropertyValue $priorSnapUncheck -Force
                    $gate | Add-Member -NotePropertyName rework -NotePropertyValue $reworkMetaUncheck -Force
                }
                $finalStatus = 'needs-polish'
            }

            if (-not $accScopeBlocked) {
                # Refresh artifact from DiffProvider when present so the re-panel sees labor.
                if ($DiffProvider) {
                    try {
                        $produced2 = [string](& $DiffProvider)
                        if (-not [string]::IsNullOrWhiteSpace($produced2)) {
                            Set-Content -LiteralPath (Join-Path $RunDir 'changes.diff') -Value $produced2 -Encoding utf8NoBOM
                            $art = $produced2
                        }
                    } catch { }
                }

                $gate2 = $null
                $gate2Err = $null
                try {
                    $gate2 = if ($Gater) { & $Gater $art $plan.goal }
                            else {
                                $gateArgs2 = @{
                                    Artifact = $art; Task = $plan.goal; MaxCostTier = $MaxCostTier
                                    FleetPath = $FleetPath; ToolsPath = $ToolsPath
                                }
                                if ($AcceptancePanel) { $gateArgs2['Panel'] = $true }
                                if ($AcceptanceFailLoud) { $gateArgs2['FailLoud'] = $true }
                                Invoke-AcceptanceGate @gateArgs2
                            }
                } catch { $gate2 = $null; $gate2Err = $_.Exception.Message }

                # Retain both verdicts: prior on disk + on the final gate object.
                $priorSnap = [ordered]@{
                    verdict = [string]$priorGate.verdict
                    reason = [string]$priorGate.reason
                    counts = $priorGate.counts
                    polish_brief = [string]$priorGate.polish_brief
                    findings = @($priorGate.findings)
                }
                ($priorSnap | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance-prior.json') -Encoding utf8NoBOM

                if ($null -eq $gate2 -or -not $gate2.verdict) {
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-failed' -Level 'warn' -Message "acceptance rework re-panel produced no verdict$(if ($gate2Err) { ": $gate2Err" })")
                    # Halt loudly; keep prior polish as the gate result with prior retained.
                    $gate = $priorGate
                    if ($gate -is [System.Collections.IDictionary]) {
                        $gate['prior_acceptance'] = $priorSnap
                        $gate['rework'] = @{ attempted = $true; evidence_path = $accEvidPath; outcome = 'failed'; reason = 're-panel-no-verdict' }
                    } else {
                        $gate | Add-Member -NotePropertyName prior_acceptance -NotePropertyValue $priorSnap -Force
                        $gate | Add-Member -NotePropertyName rework -NotePropertyValue @{ attempted = $true; evidence_path = $accEvidPath; outcome = 'failed' } -Force
                    }
                    # Round-3 review: a LOST re-panel signal is degraded, not needs-polish.
                    # The re-run is the same acceptance signal as the first gate — nobody
                    # looked at the reworked artifact, so 'needs-polish' would report a
                    # verdict that was never produced.
                    $finalStatus = 'acceptance-degraded'
                } else {
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Message "acceptance re-panel verdict: $($gate2.verdict) — $($gate2.reason)")
                    if ($gate2 -is [System.Collections.IDictionary]) {
                        $gate2['prior_acceptance'] = $priorSnap
                        $gate2['rework'] = @{
                            attempted = $true; evidence_path = $accEvidPath
                            outcome = if ([string]$gate2.verdict -eq 'accept') { 'passed' } else { 'failed' }
                            labor_ok = [bool]$accRwResult.ok
                        }
                    } else {
                        $gate2 | Add-Member -NotePropertyName prior_acceptance -NotePropertyValue $priorSnap -Force
                        $gate2 | Add-Member -NotePropertyName rework -NotePropertyValue @{
                            attempted = $true; evidence_path = $accEvidPath
                            outcome = if ([string]$gate2.verdict -eq 'accept') { 'passed' } else { 'failed' }
                        } -Force
                    }
                    $gate = $gate2
                    # Same C3 rule on the rework re-run, and the same ordering as the first
                    # gate: a reject the surviving reviewers actually produced outranks the
                    # fact that the panel was short a role.
                    if ([string]$gate2.verdict -eq 'reject') {
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-failed' -Level 'warn' -Message 'acceptance rework failed — panel reject')
                        $finalStatus = 'rejected'
                    } elseif ($gate2.degraded -or [string]$gate2.verdict -eq 'unreviewed') {
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-failed' -Level 'warn' -Message "acceptance rework panel degraded — verdict $($gate2.verdict)")
                        $finalStatus = 'acceptance-degraded'
                    } elseif ([string]$gate2.verdict -eq 'accept') {
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-passed' -Message 'acceptance rework passed — panel accept')
                        $finalStatus = 'completed'
                    } else {
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $accTask.id -Kind 'task-rework-failed' -Level 'warn' -Message "acceptance rework failed — panel $($gate2.verdict)")
                        $finalStatus = if ($AcceptanceFailLoud) { 'needs-polish' } else { $finalStatus }
                    }
                }
            }
        }
    }
    if ($acceptanceEnabled -and $AcceptanceFailLoud -and $diffProviderFailed) {
        $finalStatus = 'acceptance-degraded'
    }
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate -TaskCosts $taskCosts)
}
