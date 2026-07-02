#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:optimize-prompt runner. GEPA evolution over the Conductor's planner
  prompt: candidate pool + two-model reflect/mutate + minibatch judge + dual
  acceptance gate.
.DESCRIPTION
  Default run PROPOSES a gate-surviving candidate for human review; nothing
  is deployed. -Apply promotes the survivor to champion (timestamped backup
  kept). -Pool prints the candidate-pool report instead of evolving.
#>
param(
    [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
    [ValidateSet('local','free','paid')][string]$ReflectTier,
    [int]$MaxRuns = 5,
    [int]$Generations = 1,
    [switch]$Apply,
    [switch]$Pool,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'optimize-prompt-lib.ps1')

if ($Pool) {
    $loaded = Get-PromptPool
    if (-not $loaded.ok) {
        [Console]::Error.WriteLine("Pool unavailable: $($loaded.reason)")
        exit 2
    }
    if ($Json) { ConvertTo-Json -InputObject $loaded.pool -Depth 10; exit 0 }
    Write-Host "`n## Prompt candidate pool (champion: $($loaded.pool.champion))`n"
    $fmt = "{0,-6} {1,-9} {2,-9} {3,-7} {4,7} {5,7} {6,5} {7,10}"
    Write-Host ($fmt -f 'id', 'status', 'origin', 'parent', 'tokens', 'wr_ch', 'sel', 'live_runs')
    foreach ($c in @($loaded.pool.candidates)) {
        $wr = if ($null -ne $c.offline.minibatch.win_rate_vs_champion) { ('{0:n2}' -f [double]$c.offline.minibatch.win_rate_vs_champion) } else { '-' }
        $par = if ($c.parent) { [string]$c.parent } else { '-' }
        Write-Host ($fmt -f $c.id, $c.status, $c.origin, $par, $c.offline.prompt_tokens, $wr, $c.offline.times_selected, $c.live.runs)
        if (($c.status -eq 'retired') -and $c.retired_reason) { Write-Host ("       retired: " + $c.retired_reason) }
    }
    exit 0
}

$evoParams = @{ MaxRuns = $MaxRuns; Generations = $Generations; MaxCostTier = $MaxCostTier; Apply = $Apply }
if ($ReflectTier) { $evoParams.ReflectTier = $ReflectTier }
$res = Invoke-PromptEvolution @evoParams

if ($Json) {
    ConvertTo-Json -InputObject $res -Depth 10
    if (-not $res.success) { exit 2 }
} else {
    foreach ($g in @($res.generations)) {
        $status = if ($g.pass) { 'SURVIVED' } else { "retired: $((@($g.reasons)) -join '; ')" }
        Write-Host ("generation {0}: parent {1} -> child {2} — {3}" -f $g.generation, $g.parent, ($g.child ?? '-'), $status)
    }
    if ($res.success) {
        if ($res.applied) {
            Write-Host "`n## Prompt Evolution Applied`n"
            Write-Host $res.reason
            Write-Host "The previous live prompt was backed up alongside it; see -Pool for the champion swap."
        } else {
            Write-Host "`n## Prompt Evolution Proposed`n"
            Write-Host "$($res.reason): $($res.candidate_path)"
            Write-Host "Re-run with -Apply to promote it to champion and deploy."
        }
    } else {
        [Console]::Error.WriteLine("Prompt evolution produced no deployable candidate: $($res.reason)")
        exit 2
    }
}
