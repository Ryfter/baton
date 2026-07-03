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
    [ValidateSet('on','off')][string]$Shadow,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'optimize-prompt-lib.ps1')

if ($Shadow) {
    $loaded = Get-PromptPool
    if (-not $loaded.ok) {
        [Console]::Error.WriteLine("Pool unavailable: $($loaded.reason)")
        exit 2
    }
    $loaded.pool.shadow = ($Shadow -eq 'on')
    Save-PromptPool -Pool $loaded.pool
    Write-Host "Shadow A/B is now $($Shadow.ToUpper())."
    exit 0
}

if ($Pool) {
    $loaded = Get-PromptPool
    if (-not $loaded.ok) {
        [Console]::Error.WriteLine("Pool unavailable: $($loaded.reason)")
        exit 2
    }
    if ($Json) { ConvertTo-Json -InputObject $loaded.pool -Depth 10; exit 0 }
    Write-Host "`n## Prompt candidate pool (champion: $($loaded.pool.champion))`n"
    $fmt = "{0,-6} {1,-9} {2,-9} {3,-7} {4,7} {5,6} {6,4} {7,5} {8,4} {9,4} {10,4} {11,8} {12,8} {13,9}"
    Write-Host ($fmt -f 'id', 'status', 'origin', 'parent', 'tokens', 'wr_ch', 'sel', 'runs', 'acc', 'pol', 'rej', 'real$', 'rework$', '$/accept')
    foreach ($c in @($loaded.pool.candidates)) {
        $wr = if ($null -ne $c.offline.minibatch.win_rate_vs_champion) { ('{0:n2}' -f [double]$c.offline.minibatch.win_rate_vs_champion) } else { '-' }
        $par = if ($c.parent) { [string]$c.parent } else { '-' }
        $cpa = Get-CostPerAccept -Live $c.live
        $cpaStr = if ($null -ne $cpa) { ('{0:n2}' -f [double]$cpa) } else { '-' }
        Write-Host ($fmt -f $c.id, $c.status, $c.origin, $par, $c.offline.prompt_tokens, $wr, $c.offline.times_selected, `
            $c.live.runs, $c.live.accept, $c.live.polish, $c.live.reject, `
            ('{0:n2}' -f [double]$c.live.realized_cost_usd), ('{0:n2}' -f [double]$c.live.rework_cost_usd), $cpaStr)
        if (($c.status -eq 'retired') -and $c.retired_reason) {
            $when = if ($c.retired_at) { " $($c.retired_at)" } else { '' }
            $who = if ($c.retired_by) { " by $($c.retired_by)" } else { '' }
            Write-Host ("       retired${when}${who}: " + $c.retired_reason)
        }
    }
    Write-Host ""
    Write-Host ("Shadow A/B: " + $(if (Get-ShadowEnabled -Pool $loaded.pool) { 'ON' } else { 'OFF (--shadow on to enable)' }))
    $sv = Get-ShadowVerdict -Pool $loaded.pool
    switch ($sv.state) {
        'no-challenger' { Write-Host 'Shadow verdict: no active challenger — run an evolution to produce one.' }
        'insufficient'  { Write-Host ("Shadow verdict: insufficient evidence — challenger {0}/{2}, champion {1}/{2} gated runs." -f $sv.challenger_gated, $sv.champion_gated, $sv.threshold) }
        'promote'       { Write-Host ("Shadow verdict: PROMOTE $($sv.challenger_id) — cost/accept {0} vs champion {1}. Run --apply to deploy." -f $(if ($null -ne $sv.challenger_cpa) { '{0:n4}' -f [double]$sv.challenger_cpa } else { 'n/a' }), $(if ($null -ne $sv.champion_cpa) { '{0:n4}' -f [double]$sv.champion_cpa } else { 'n/a (0 accepts)' })) }
        'retire'        { Write-Host ("Shadow verdict: challenger $($sv.challenger_id) is losing in dollars — it will auto-retire on the next gated run.") }
        'stalemate'     { Write-Host 'Shadow verdict: stalemate — no dollars separation at threshold; keep gathering.' }
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
