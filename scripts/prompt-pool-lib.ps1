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

# Slice B: minimum gated live runs PER VARIANT before the dollars verdict.
$script:ShadowMinGatedRuns = 5

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
        # ConvertFrom-Json auto-parses ISO8601 datetime strings as DateTime objects.
        # Preserve them as ISO8601 strings (with Z suffix) for timestamp provenance fields.
        foreach ($c in @($pool.candidates)) {
            if (($c.created -is [datetime])) { $c.created = $c.created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
            if (($c.retired_at -is [datetime])) { $c.retired_at = $c.retired_at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        }
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
    # [string]$Parent coerces $null to '' — normalize back so seed lineage
    # serializes as JSON null (Slice B reads parentage from this field).
    $parentVal = if ([string]::IsNullOrEmpty($Parent)) { $null } else { $Parent }
    return @{
        id = $Id; file = "$Id.txt"; parent = $parentVal; origin = $Origin
        created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        status = $Status
        retired_reason = $null
        retired_at = $null
        retired_by = $null
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

function Set-CandidateRetired {
    <# The single retirement door (Slice B): every path that retires a
       candidate goes through here so why (reason), when (retired_at), and
       what beat/replaced it (retired_by) are always on the record. Mutates
       the in-memory pool; the caller saves. #>
    param(
        [Parameter(Mandatory)][hashtable]$Pool,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Reason,
        [string]$By
    )
    $hit = @($Pool.candidates | Where-Object { $_.id -eq $Id })
    if (@($hit).Count -eq 0) { return $false }
    $c = $hit[0]
    $c.status = 'retired'
    $c.retired_reason = $Reason
    $c.retired_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # [string]$By coerces $null to '' — normalize back so JSON carries null.
    $c.retired_by = if ([string]::IsNullOrEmpty($By)) { $null } else { $By }
    return $true
}

function Get-ShadowEnabled {
    <# Kill switch: pool.shadow. ABSENT key reads as enabled (on by default). #>
    param([Parameter(Mandatory)][hashtable]$Pool)
    if ($Pool.ContainsKey('shadow')) { return [bool]$Pool.shadow }
    return $true
}

function Select-ShadowChallenger {
    <# The active challenger: highest offline win rate among status='candidate'
       members with a non-null (non-stale) score; tie -> highest id (newest).
       $null when nothing is live-testable. #>
    param([Parameter(Mandatory)][hashtable]$Pool)
    $scored = @($Pool.candidates | Where-Object {
        ($_.status -eq 'candidate') -and ($null -ne $_.offline.minibatch.win_rate_vs_champion)
    })
    if (@($scored).Count -eq 0) { return $null }
    return @($scored | Sort-Object `
        @{ Expression = { [double]$_.offline.minibatch.win_rate_vs_champion }; Descending = $true },
        @{ Expression = { [string]$_.id }; Descending = $true })[0]
}

function Resolve-ShadowVariant {
    <# Which prompt does THIS /baton:go run use? Fail-open by construction:
       any problem returns shadow=$false and the caller behaves exactly as
       today. Never throws; never writes the pool (assignment is not
       evidence — counters move only at accrual). Challenger text is always
       validated upfront (fail-safe). #>
    param([string]$PoolDir = (Get-PromptPoolDir))
    $loaded = Get-PromptPool -PoolDir $PoolDir
    if (-not $loaded.ok) {
        $why = if ($loaded.reason -eq 'absent') { 'absent' } else { 'corrupt' }
        return @{ shadow = $false; reason = $why }
    }
    $pool = $loaded.pool
    if (-not (Get-ShadowEnabled -Pool $pool)) { return @{ shadow = $false; reason = 'disabled' } }
    $champHit = @($pool.candidates | Where-Object { $_.id -eq $pool.champion })
    if (@($champHit).Count -eq 0) { return @{ shadow = $false; reason = 'corrupt' } }
    $champ = $champHit[0]
    $chall = Select-ShadowChallenger -Pool $pool
    if ($null -eq $chall) { return @{ shadow = $false; reason = 'no challenger' } }
    # Validate challenger text upfront (fail-safe): if unreadable, fail open
    # regardless of who would take the run.
    $textPath = Join-Path $PoolDir ([string]$chall.file)
    $text = $null
    try { if (Test-Path $textPath) { $text = Get-Content -Raw -LiteralPath $textPath } } catch { $text = $null }
    $okText = $false
    if (-not [string]::IsNullOrEmpty($text)) {
        $okText = $text.Contains('{{schema}}') -and $text.Contains('{{evi}}') -and $text.Contains('{{Goal}}')
    }
    if (-not $okText) { return @{ shadow = $false; reason = 'challenger unreadable' } }
    # Alternation: fewer live runs takes this run; tie -> challenger (it is
    # the one needing evidence). Self-balancing across aborted/ungated runs.
    if (([int]$champ.live.runs) -lt ([int]$chall.live.runs)) {
        return @{ shadow = $true; variant_id = [string]$champ.id; role = 'champion'
                  template = $null; challenger_id = [string]$chall.id }
    }
    return @{ shadow = $true; variant_id = [string]$chall.id; role = 'challenger'
              template = $text; challenger_id = [string]$chall.id }
}

function Add-LiveRunResult {
    <# Accrue one live run's realized cost (and verdict, when gated) to a
       variant's live.* fields. Rework dollars = every dollar spent on a run
       that ended polish/reject (Kevin's cost-to-accepted-outcome metric).
       Mutates the in-memory pool; the caller saves. #>
    param(
        [Parameter(Mandatory)][hashtable]$Pool,
        [Parameter(Mandatory)][string]$VariantId,
        [Parameter(Mandatory)][double]$CostUsd,
        [ValidateSet('accept','polish','reject')][string]$Verdict
    )
    $hit = @($Pool.candidates | Where-Object { $_.id -eq $VariantId })
    if (@($hit).Count -eq 0) { return $false }
    $live = $hit[0].live
    $live.runs = ([int]$live.runs) + 1
    $live.realized_cost_usd = [math]::Round(([double]$live.realized_cost_usd) + $CostUsd, 6)
    if ($Verdict) {
        $live[$Verdict] = ([int]$live[$Verdict]) + 1
        if ($Verdict -in @('polish', 'reject')) {
            $live.rework_cost_usd = [math]::Round(([double]$live.rework_cost_usd) + $CostUsd, 6)
        }
    }
    return $true
}

function Get-CostPerAccept {
    <# The north-star per-variant figure: total realized dollars per ACCEPTED
       outcome. null when nothing has been accepted yet. #>
    param([Parameter(Mandatory)]$Live)
    if (([int]$Live.accept) -le 0) { return $null }
    return [math]::Round(([double]$Live.realized_cost_usd) / [int]$Live.accept, 4)
}

function Get-ShadowVerdict {
    <# The dollars verdict. gated(v) = accept+polish+reject. States:
       no-challenger | insufficient | promote | retire | stalemate.
       Pure read — the caller acts (Complete-Run auto-retires; promotion is
       always human --apply, d070). #>
    param([Parameter(Mandatory)][hashtable]$Pool)
    $champHit = @($Pool.candidates | Where-Object { $_.id -eq $Pool.champion })
    $chall = Select-ShadowChallenger -Pool $Pool
    if ((@($champHit).Count -eq 0) -or ($null -eq $chall)) {
        return @{ state = 'no-challenger'; threshold = $script:ShadowMinGatedRuns }
    }
    $champ = $champHit[0]
    $cg = ([int]$champ.live.accept) + ([int]$champ.live.polish) + ([int]$champ.live.reject)
    $hg = ([int]$chall.live.accept) + ([int]$chall.live.polish) + ([int]$chall.live.reject)
    $verdict = @{
        champion_id = [string]$champ.id; challenger_id = [string]$chall.id
        champion_gated = $cg; challenger_gated = $hg
        champion_cpa = (Get-CostPerAccept -Live $champ.live)
        challenger_cpa = (Get-CostPerAccept -Live $chall.live)
        threshold = $script:ShadowMinGatedRuns
    }
    if (($cg -lt $script:ShadowMinGatedRuns) -or ($hg -lt $script:ShadowMinGatedRuns)) {
        $verdict.state = 'insufficient'
        return $verdict
    }
    $cc = $verdict.champion_cpa
    $hc = $verdict.challenger_cpa
    if (($null -eq $cc) -and ($null -eq $hc)) { $verdict.state = 'stalemate' }
    elseif ($null -eq $hc) { $verdict.state = 'retire' }
    elseif ($null -eq $cc) { $verdict.state = 'promote' }
    elseif (([double]$hc) -lt ([double]$cc)) { $verdict.state = 'promote' }
    elseif (([double]$hc) -gt ([double]$cc)) { $verdict.state = 'retire' }
    else { $verdict.state = 'stalemate' }
    return $verdict
}
