#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing calibration (Slice 4). Fans out across ALL candidates for a capability
  on one prompt, judge-scores each, and records per-candidate human ratings. The exploration
  twin of Slice 2's escalate-and-stop dispatch.
.DESCRIPTION
  Dot-sources routing-dispatch.ps1 (which pulls routing-lib -> routing-learn + fleet-lib), so
  Select-Capability, Invoke-RoutedCandidate, Get-LlmJudgeGrader, and Add-CapabilityRating are
  all in scope. Ratings persist to the GitHub-backed knowledge repo; the journal stays local.
  See docs/superpowers/specs/2026-06-09-routing-s4-calibration-mode-design.md.
#>

. "$PSScriptRoot/routing-dispatch.ps1"

function Invoke-CapabilityCalibration {
    <# Dispatch EVERY candidate serving -Capability (within the tier cap), grade each, journal
       each, and return all rows ranked by score desc. Never short-circuits. -Grader wins; else
       -Judge wires the LLM-judge; else heuristic. -Dispatcher/-JudgeDispatcher are test injection. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [switch]$RequireLocal,
        [int]$TimeoutS = 120,
        [scriptblock]$Grader,
        [scriptblock]$Dispatcher,
        [switch]$Judge,
        [string]$JudgeModel,
        [scriptblock]$JudgeDispatcher,
        [int]$ExcerptChars = 280,
        [string]$ToolsPath = (Join-Path $HOME '.claude/tools.yaml'),
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl')
    )
    $sel = @{ Capability = $Capability; ToolsPath = $ToolsPath; FleetPath = $FleetPath }
    if ($RequireLocal) { $sel['RequireLocal'] = $true }
    if ($MaxCostTier)  { $sel['MaxCostTier']  = $MaxCostTier }
    $candidates = Select-Capability @sel

    # Same grader resolution as Invoke-RoutedCapability: -Grader wins; -Judge wires the judge; else heuristic.
    $effGrader = if ($Grader) { $Grader }
                 elseif ($Judge) { Get-LlmJudgeGrader -JudgeModel $JudgeModel -FleetPath $FleetPath -JudgeDispatcher $JudgeDispatcher }
                 else { $null }

    if (-not $candidates -or $candidates.Count -eq 0) {
        return [pscustomobject]@{ status='no-candidate'; capability=$Capability; candidates=@() }
    }

    $rows = [System.Collections.ArrayList]@()
    foreach ($c in $candidates) {
        $rc = Invoke-RoutedCandidate -Capability $Capability -Candidate $c -Prompt $Prompt `
            -EffGrader $effGrader -Dispatcher $Dispatcher -TimeoutS $TimeoutS `
            -ToolsPath $ToolsPath -FleetPath $FleetPath -JournalPath $JournalPath
        $excerpt = (([string]$rc.result.stdout) -replace '\s+', ' ').Trim()
        if ($excerpt.Length -gt $ExcerptChars) { $excerpt = $excerpt.Substring(0, $ExcerptChars) }
        [void]$rows.Add([pscustomobject]@{
            candidate  = $rc.attempt.candidate; source = $rc.attempt.source; cost_tier = $rc.attempt.cost_tier
            passed     = $rc.attempt.passed;     score  = $rc.attempt.score;  reason    = $rc.attempt.reason
            duration_s = $rc.attempt.duration_s; excerpt = $excerpt
        })
    }
    $ranked = @($rows.ToArray() | Sort-Object -Property score -Descending)
    return [pscustomobject]@{ status='calibrated'; capability=$Capability; candidates=$ranked }
}

function Add-CalibrationRatings {
    <# Apply a batch of per-candidate verdicts from a "name=good name=bad ..." spec. Re-derives
       each candidate's source via Select-Capability (no dispatch), then calls Add-CapabilityRating.
       Tokens that are malformed, have a non good|bad verdict, or name an unknown candidate are
       warned and skipped. Returns @{ applied; skipped }. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Spec,
        [string]$Note = '',
        [string]$ToolsPath = (Join-Path $HOME '.claude/tools.yaml'),
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$RatingsPath = (Join-Path $HOME '.claude/knowledge/universal/routing-ratings.jsonl'),
        [string]$Timestamp
    )
    # Select-Capability returns a comma-protected ,([object[]]); assign directly (never @()-wrap,
    # which collapses it to a single nested element). Mirrors Invoke-RoutedCapability's consumer.
    $cands = Select-Capability -Capability $Capability -ToolsPath $ToolsPath -FleetPath $FleetPath
    $srcByName = @{}
    foreach ($c in $cands) { $srcByName[$c.name] = $c.source }

    $applied = 0; $skipped = 0
    foreach ($tok in @($Spec -split '\s+' | Where-Object { $_ -ne '' })) {
        $kv = $tok -split '=', 2
        if ($kv.Count -ne 2) { Write-Warning "calibration rating: malformed token '$tok'"; $skipped++; continue }
        $name = $kv[0]; $rating = $kv[1].ToLower()
        if ($rating -ne 'good' -and $rating -ne 'bad') { Write-Warning "calibration rating: bad verdict in '$tok' (use good|bad)"; $skipped++; continue }
        if (-not $srcByName.ContainsKey($name)) { Write-Warning "calibration rating: '$name' is not a candidate for $Capability"; $skipped++; continue }
        $addArgs = @{ Capability=$Capability; Candidate=$name; Source=$srcByName[$name]; Rating=$rating; Note=$Note; RatingsPath=$RatingsPath }
        if ($Timestamp) { $addArgs['Timestamp'] = $Timestamp }
        Add-CapabilityRating @addArgs
        $applied++
    }
    return @{ applied = $applied; skipped = $skipped }
}
