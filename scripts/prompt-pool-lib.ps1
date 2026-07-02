#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Candidate-pool state + Pareto math for the GEPA optimizer graduation.
.DESCRIPTION
  Pool = BATON_HOME/prompts/pool/pool.json manifest + one pNNN.txt per
  candidate. Box-private: never seeded by bootstrap, never leaves the box.
  Exactly one member has status 'champion' (the live prompt's bookkeeping
  twin); 'candidate' = gate survivor awaiting human --apply; 'retired'
  members are kept as reflection fuel, never deleted.
.NOTES
  House trap: under $ErrorActionPreference = 'Stop', Write-Error THROWS —
  failures are reported via the returned reason strings instead.
#>

. "$PSScriptRoot/baton-home.ps1"

function Get-PromptPoolDir {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'prompts/pool')
}

function Get-PromptTokenEstimate {
    <# ceil(chars/4): no tokenizer in PowerShell; the estimate only needs to
       be monotone and consistent across candidates. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [int][math]::Ceiling($Text.Length / 4.0)
}

function Get-PromptPool {
    param([string]$PoolDir = (Get-PromptPoolDir))
    $manifest = Join-Path $PoolDir 'pool.json'
    if (-not (Test-Path $manifest)) { return @{ ok = $false; pool = $null; reason = 'absent' } }
    try {
        $pool = Get-Content -Raw $manifest | ConvertFrom-Json -AsHashtable
    } catch {
        return @{ ok = $false; pool = $null; reason = "corrupt manifest at ${manifest}: $($_.Exception.Message)" }
    }
    if (($null -eq $pool) -or ($null -eq $pool.candidates)) {
        return @{ ok = $false; pool = $null; reason = "corrupt manifest at ${manifest}: missing candidates" }
    }
    return @{ ok = $true; pool = $pool; reason = 'loaded' }
}

function Save-PromptPool {
    param([Parameter(Mandatory)][hashtable]$Pool, [string]$PoolDir = (Get-PromptPoolDir))
    if (-not (Test-Path $PoolDir)) { New-Item -ItemType Directory -Force -Path $PoolDir | Out-Null }
    ConvertTo-Json -InputObject $Pool -Depth 10 |
        Set-Content -LiteralPath (Join-Path $PoolDir 'pool.json') -Encoding utf8NoBOM
}

function New-PoolCandidateRecord {
    <# Schema v1 candidate record (spec: pool schema). live.* is written only
       by Slice B (shadow A/B); Slice A creates the fields at zero. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][string]$Parent,
        [Parameter(Mandatory)][ValidateSet('seed','mutation')][string]$Origin,
        [Parameter(Mandatory)][ValidateSet('champion','candidate','retired')][string]$Status,
        [Parameter(Mandatory)][int]$PromptTokens
    )
    return @{
        id = $Id; file = "$Id.txt"; parent = $Parent; origin = $Origin
        created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        status = $Status
        retired_reason = $null
        offline = @{
            times_selected = 0
            prompt_tokens = $PromptTokens
            minibatch = @{ wins = 0; losses = 0; ties = 0; win_rate_vs_champion = $null; examples = @() }
        }
        live = @{ runs = 0; accept = 0; polish = 0; reject = 0; realized_cost_usd = 0.0; rework_cost_usd = 0.0 }
    }
}

function Initialize-PromptPool {
    <# Seed the pool from the live planner prompt as p001/champion.
       The champion's win_rate_vs_champion is 0.5 by definition (it is the
       reference every minibatch measures against). #>
    param([Parameter(Mandatory)][string]$SeedPromptPath, [string]$PoolDir = (Get-PromptPoolDir))
    if (-not (Test-Path $SeedPromptPath)) {
        return @{ ok = $false; pool = $null; reason = "seed prompt not found at $SeedPromptPath" }
    }
    $seedText = Get-Content -Raw $SeedPromptPath
    if (-not (Test-Path $PoolDir)) { New-Item -ItemType Directory -Force -Path $PoolDir | Out-Null }
    $seed = New-PoolCandidateRecord -Id 'p001' -Parent $null -Origin 'seed' -Status 'champion' `
        -PromptTokens (Get-PromptTokenEstimate -Text $seedText)
    $seed.offline.minibatch.win_rate_vs_champion = 0.5
    Set-Content -LiteralPath (Join-Path $PoolDir 'p001.txt') -Value $seedText -Encoding utf8NoBOM
    $pool = @{ schema = 1; champion = 'p001'; candidates = @($seed) }
    Save-PromptPool -Pool $pool -PoolDir $PoolDir
    return @{ ok = $true; pool = $pool; reason = 'seeded' }
}

function Get-NextCandidateId {
    param([Parameter(Mandatory)][hashtable]$Pool)
    $max = 0
    foreach ($c in @($Pool.candidates)) {
        if (([string]$c.id) -match '^p(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ('p{0:d3}' -f ($max + 1))
}

function Get-ParetoFront {
    <# Non-dominated set of ACTIVE (champion|candidate) members on the axes
       (win_rate_vs_champion: higher better, prompt_tokens: lower better).
       Unscored members (null win rate — e.g. stale after a champion swap)
       are excluded until re-evaluated. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Candidates)
    $active = @($Candidates | Where-Object {
        ($_.status -in @('champion', 'candidate')) -and ($null -ne $_.offline.minibatch.win_rate_vs_champion)
    })
    if ($active.Count -eq 0) { return @() }
    $front = [System.Collections.ArrayList]@()
    foreach ($a in $active) {
        $awr = [double]$a.offline.minibatch.win_rate_vs_champion
        $at = [int]$a.offline.prompt_tokens
        $dominated = $false
        foreach ($b in $active) {
            if ($b.id -eq $a.id) { continue }
            $bwr = [double]$b.offline.minibatch.win_rate_vs_champion
            $bt = [int]$b.offline.prompt_tokens
            if (($bwr -ge $awr) -and ($bt -le $at) -and (($bwr -gt $awr) -or ($bt -lt $at))) {
                $dominated = $true; break
            }
        }
        if (-not $dominated) { [void]$front.Add($a) }
    }
    if ($front.Count -eq 0) { return @() }
    return ,([array]$front)
}

function Select-ParentCandidate {
    <# Frequency-weighted random pick from the Pareto front (DeepEval):
       weight = 1/(1+times_selected) spreads exploration. Empty front (young
       or all-stale pool) degenerates to the champion. -Draw is the
       determinism seam: receives the total weight, returns [0,total). #>
    param(
        [Parameter(Mandatory)][hashtable]$Pool,
        [scriptblock]$Draw = { param($total) Get-Random -Minimum 0.0 -Maximum $total }
    )
    $front = Get-ParetoFront -Candidates @($Pool.candidates)
    if (@($front).Count -eq 0) {
        return @($Pool.candidates | Where-Object { $_.id -eq $Pool.champion })[0]
    }
    $total = 0.0
    foreach ($c in @($front)) { $total += 1.0 / (1.0 + [int]$c.offline.times_selected) }
    $x = [double](& $Draw $total)
    foreach ($c in @($front)) {
        $x -= 1.0 / (1.0 + [int]$c.offline.times_selected)
        if ($x -lt 0) { return $c }
    }
    return @($front)[-1]
}

function Test-DualGate {
    <# Spec dual gate: (a) child BEATS its parent on the minibatch
       (win_rate_vs_parent strictly > 0.5; null = all ties/no examples = no
       evidence = fail), AND (b) child is Pareto-non-dominated among the
       pool's active scored members. Returns @{ pass; reasons }. #>
    param(
        [Parameter(Mandatory)][hashtable]$Child,
        [Parameter(Mandatory)][AllowNull()][object]$WinRateVsParent,
        [Parameter(Mandatory)][hashtable]$Pool
    )
    $reasons = [System.Collections.ArrayList]@()
    if ($null -eq $WinRateVsParent) {
        [void]$reasons.Add('no evidence vs parent (all ties or no scoreable examples)')
    } elseif (([double]$WinRateVsParent) -le 0.5) {
        [void]$reasons.Add("did not beat parent (win rate $WinRateVsParent)")
    }
    if ($null -eq $Child.offline.minibatch.win_rate_vs_champion) {
        [void]$reasons.Add('no evidence vs champion (all ties or no scoreable examples)')
    } else {
        $cwr = [double]$Child.offline.minibatch.win_rate_vs_champion
        $ct = [int]$Child.offline.prompt_tokens
        $active = @($Pool.candidates | Where-Object {
            ($_.status -in @('champion', 'candidate')) -and ($null -ne $_.offline.minibatch.win_rate_vs_champion)
        })
        foreach ($b in $active) {
            $bwr = [double]$b.offline.minibatch.win_rate_vs_champion
            $bt = [int]$b.offline.prompt_tokens
            if (($bwr -ge $cwr) -and ($bt -le $ct) -and (($bwr -gt $cwr) -or ($bt -lt $ct))) {
                [void]$reasons.Add("Pareto-dominated by $($b.id)")
                break
            }
        }
    }
    if ($reasons.Count -eq 0) { return @{ pass = $true; reasons = @() } }
    return @{ pass = $false; reasons = @($reasons) }
}
