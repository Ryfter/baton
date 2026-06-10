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
