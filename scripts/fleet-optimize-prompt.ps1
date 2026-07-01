#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:optimize-prompt runner. Executes GEPA-style reflective optimization
  on the Conductor's planner prompt based on historical failures.
.DESCRIPTION
  Default run PROPOSES a candidate prompt file for human review; nothing is
  deployed. Pass -Apply to validate and deploy the candidate to the live
  prompt (a timestamped backup of the previous live copy is kept alongside it).
#>
param(
    [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
    [int]$MaxRuns = 5,
    [switch]$Apply,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'optimize-prompt-lib.ps1')

$res = Invoke-PromptOptimizer -MaxRuns $MaxRuns -MaxCostTier $MaxCostTier -Apply:$Apply

if ($Json) {
    $res | ConvertTo-Json -Compress
} else {
    if ($res.success) {
        if ($res.applied) {
            Write-Host "`n## Prompt Optimization Applied`n"
            Write-Host "The Conductor planner prompt has been mutated and deployed (the previous live copy was backed up alongside it)."
        } else {
            Write-Host "`n## Prompt Optimization Proposed`n"
            Write-Host "A candidate prompt was written to $($res.candidate_path) for review. Re-run with -Apply to deploy it."
        }
    } else {
        [Console]::Error.WriteLine("Prompt optimization failed: $($res.reason)")
        exit 2
    }
}
