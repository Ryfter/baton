#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing learning loop (Slice 3). Aggregates the user's ratings, LLM-judge
  scores, and heuristic pass-history into a learned per-(capability,candidate) quality,
  captures ratings, and provides an LLM-judge grader for the Slice 2 -Grader seam.
.DESCRIPTION
  Dot-sourced by routing-lib.ps1 (so Select-Capability and routing-dispatch.ps1 both see
  these functions). Ratings persist to the GitHub-backed knowledge repo; the journal stays
  local. See docs/superpowers/specs/2026-06-08-routing-s3-learning-loop-design.md.
#>

. "$PSScriptRoot/baton-home.ps1"
$script:DefaultRatingsPath = (Join-Path $HOME '.claude/knowledge/universal/routing-ratings.jsonl')

function Read-JsonlRows {
    <# Robust JSONL reader: missing path -> empty; malformed lines skipped. Returns object[].
       Contract: callers wrap the result in @(...) before .Count/indexing. The plain
       (non unary-comma) return is deliberate — every consumer here uses @(), and the
       unary-comma idiom double-unrolls under @(), corrupting counts (see test suite). #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return ([object[]]@()) }
    $out = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return ([object[]]$out.ToArray())
}

function Get-CapabilityRatings {
    <# All rating rows (optionally filtered by capability/candidate). #>
    param(
        [string]$Capability, [string]$Candidate,
        [string]$RatingsPath = $script:DefaultRatingsPath
    )
    $rows = Read-JsonlRows -Path $RatingsPath
    if ($Capability) { $rows = @($rows | Where-Object { $_.capability -eq $Capability }) }
    if ($Candidate)  { $rows = @($rows | Where-Object { $_.candidate  -eq $Candidate  }) }
    return ([object[]]@($rows))   # callers wrap in @(); see Read-JsonlRows contract note
}

function Add-CapabilityRating {
    <# Append one rating row to the GitHub-backed ratings store. Creates the dir/file.
       A write fault warns and returns; never crashes. -Timestamp injectable for tests. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$Source = '',
        [Parameter(Mandatory)][ValidateSet('good','bad')][string]$Rating,
        [string]$Note = '',
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToString('o') }
    $row = [ordered]@{
        ts = $Timestamp; capability = $Capability; candidate = $Candidate
        source = $Source; rating = $Rating; note = $Note
    }
    try {
        $dir = Split-Path -Parent $RatingsPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $RatingsPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8NoBOM
    } catch {
        Write-Warning "routing rating write failed: $($_.Exception.Message)"
    }
}

function Import-GauntletScorecard {
    <# Import a Gauntlet scorecard (the spec'd contract: run{id,date}, cells[]) into
       the ratings store as source='gauntlet' rows. Idempotent by run id. A cell whose
       model id matches a provider's model_default is recorded under the PROVIDER name
       (the routing candidate); unmapped cells keep the raw model id (future pins make
       them retroactively useful). Cells missing model/capability/quality are skipped
       and counted. Returns @{imported; skipped; unmapped; already; run_id}. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
    )
    if (-not (Test-Path $Path)) { throw "scorecard not found: $Path" }
    $sc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $sc.run -or -not $sc.run.id) { throw "scorecard missing run.id: $Path" }
    if ($null -eq $sc.cells) { throw "scorecard missing cells[]: $Path" }
    $runId = [string]$sc.run.id
    if (@(Read-JsonlRows -Path $RatingsPath | Where-Object { $_.run_id -eq $runId }).Count -gt 0) {
        return @{ imported = 0; skipped = 0; unmapped = 0; already = $true; run_id = $runId }
    }
    $pinMap = @{}
    if (Test-Path $FleetPath) {
        foreach ($p in (Read-Fleet -Path $FleetPath)) {
            if ($p.model_default) { $pinMap[[string]$p.model_default] = [string]$p.name }
        }
    }
    $imported = 0; $skipped = 0; $unmapped = 0
    $ts = if ($sc.run.date) { [string]$sc.run.date } else { (Get-Date).ToString('o') }
    $dir = Split-Path -Parent $RatingsPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    foreach ($cell in @($sc.cells)) {
        if (-not $cell.model -or -not $cell.capability -or $null -eq $cell.quality) { $skipped++; continue }
        $candidate = if ($pinMap.ContainsKey([string]$cell.model)) { $pinMap[[string]$cell.model] }
                     else { $unmapped++; [string]$cell.model }
        $row = [ordered]@{
            ts = $ts; capability = [string]$cell.capability; candidate = $candidate
            source = 'gauntlet'; score = [double]$cell.quality
            n_cases = $(if ($cell.cases) { [int]$cell.cases } else { 1 })
            run_id = $runId
        }
        Add-Content -LiteralPath $RatingsPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8NoBOM
        $imported++
    }
    return @{ imported = $imported; skipped = $skipped; unmapped = $unmapped; already = $false; run_id = $runId }
}

function Get-RoutingStats {
    <# Per-(capability,candidate) signal stats from ratings + journal. Internal. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath
    )
    # User ratings (exclude scorecard rows — they carry score, not good/bad; without
    # this filter gauntlet rows would silently DRAG DOWN the user rate).
    $rtAll = Get-CapabilityRatings -Capability $Capability -Candidate $Candidate -RatingsPath $RatingsPath
    $rt = @($rtAll | Where-Object { $_.rating -eq 'good' -or $_.rating -eq 'bad' })
    $nu = @($rt).Count
    $gu = @($rt | Where-Object { $_.rating -eq 'good' }).Count
    $ru = if ($nu -gt 0) { [double]$gu / $nu } else { 0.0 }

    # Gauntlet scorecard cells: calibration-grade evidence. Each cell contributes its
    # case count capped at 10 (one bench run must not drown live signals forever).
    $gc = @($rtAll | Where-Object { $_.source -eq 'gauntlet' -and $null -ne $_.score })
    $ng = 0; $gsum = 0.0
    foreach ($g in $gc) {
        $w = [Math]::Min([int]$(if ($g.n_cases) { $g.n_cases } else { 1 }), 10)
        $ng += $w; $gsum += $w * [double]$g.score
    }
    $rg = if ($ng -gt 0) { $gsum / $ng } else { 0.0 }

    # Journal rows for this pair
    $rows = @(Read-JsonlRows -Path $JournalPath | Where-Object { $_.capability -eq $Capability -and $_.candidate -eq $Candidate })
    $judge = @($rows | Where-Object { $_.grader -eq 'llm-judge' })
    $nj = $judge.Count
    $rj = if ($nj -gt 0) { [double](($judge | Measure-Object -Property score -Average).Average) } else { 0.0 }
    $nh = $rows.Count
    $ph = @($rows | Where-Object { $_.passed -eq $true }).Count
    $rh = if ($nh -gt 0) { [double]$ph / $nh } else { 0.0 }

    return @{
        user      = @{ rate = $ru; n = [int]$nu }
        gauntlet  = @{ rate = $rg; n = [int]$ng }
        judge     = @{ rate = $rj; n = [int]$nj }
        heuristic = @{ rate = $rh; n = [int]$nh }
    }
}

function Get-CapabilityQualityDetail {
    <# Learned quality + its provenance. Pseudo-count Bayesian blend; shrinks to -Prior. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [double]$Prior = 0.5
    )
    $s  = Get-RoutingStats -Capability $Capability -Candidate $Candidate -JournalPath $JournalPath -RatingsPath $RatingsPath
    $k  = 2.0; $Wu = 1.0; $Wg = 0.75; $Wj = 0.5; $Wh = 0.25
    $numer = ($Prior * $k) + ($Wu * $s.user.n * $s.user.rate) + ($Wg * $s.gauntlet.n * $s.gauntlet.rate) + ($Wj * $s.judge.n * $s.judge.rate) + ($Wh * $s.heuristic.n * $s.heuristic.rate)
    $denom = $k + ($Wu * $s.user.n) + ($Wg * $s.gauntlet.n) + ($Wj * $s.judge.n) + ($Wh * $s.heuristic.n)
    $q = if ($denom -gt 0) { $numer / $denom } else { $Prior }
    if ($q -lt 0.0) { $q = 0.0 }
    if ($q -gt 1.0) { $q = 1.0 }
    return @{
        quality   = [double]$q
        prior     = [double]$Prior
        user      = $s.user
        gauntlet  = $s.gauntlet
        judge     = $s.judge
        heuristic = $s.heuristic
    }
}

function Get-CapabilityQuality {
    <# Learned quality in [0,1] for a (capability, candidate). Convenience wrapper. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [double]$Prior = 0.5
    )
    return (Get-CapabilityQualityDetail -Capability $Capability -Candidate $Candidate -JournalPath $JournalPath -RatingsPath $RatingsPath -Prior $Prior).quality
}

function Get-LastRoutedAttempt {
    <# The most recent PASSING attempt in the journal — the winner the user last saw.
       Returns $null when no passing attempt exists. #>
    param([string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'))
    $rows = @(Read-JsonlRows -Path $JournalPath)
    for ($i = $rows.Count - 1; $i -ge 0; $i--) {
        if ($rows[$i].passed -eq $true) { return $rows[$i] }
    }
    return $null
}

function Get-CheapestLocalModel {
    <# Name of the first enabled local ($0) fleet model, or $null. #>
    param([string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'))
    if (-not (Test-Path $FleetPath)) { return $null }
    $local = @(Read-Fleet -Path $FleetPath | Where-Object { $_.enabled -eq $true -and $_.cost_tier -eq 'local' })
    if ($local.Count -eq 0) { return $null }
    return [string]$local[0].name
}

function Get-JudgeModel {
    <# Resolve the judge via capability claims: best enabled LOCAL provider claiming
       'judge' (Select-Capability ranking). Falls back to the first enabled local
       (Get-CheapestLocalModel) when nobody claims judge, or when this lib is loaded
       standalone without routing-lib (Select-Capability absent). Replaces the
       file-order pick that dialed an offline box on 2026-06-11. #>
    param(
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl')
    )
    if (Get-Command Select-Capability -ErrorAction SilentlyContinue) {
        $c = @(Select-Capability -Capability 'judge' -RequireLocal -FleetPath $FleetPath -ToolsPath $ToolsPath -RatingsPath $RatingsPath -JournalPath $JournalPath | Where-Object { $null -ne $_ })
        if ($c.Count -gt 0) { return [string]$c[0].name }
    }
    return Get-CheapestLocalModel -FleetPath $FleetPath
}

function Invoke-LlmJudge {
    <# Ask a cheap model to score an output 0..1 for a capability. Returns @{score;reason}.
       -Dispatcher (param: model, prompt -> raw string) is injected in tests; otherwise the
       judge dispatches via Invoke-Fleet -NoJournal. Throws on no-JSON / parse failure so the
       grader can fall back. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$JudgeModel,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [scriptblock]$Dispatcher
    )
    $rubric = @"
You are grading the OUTPUT of a tool that was asked to perform a '$Capability' task.
Score from 0.0 to 1.0 how well the OUTPUT satisfies such a request.
Reply with ONLY compact JSON: {"score": <number 0..1>, "reason": "<short>"}

OUTPUT:
$Output
"@
    if ($Dispatcher) {
        $raw = [string](& $Dispatcher $JudgeModel $rubric)
    } else {
        $r = Invoke-Fleet -Name $JudgeModel -Prompt $rubric -Path $FleetPath -NoJournal
        $raw = [string]$r.stdout
    }
    $m = [regex]::Match($raw, '\{.*\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { throw "judge returned no JSON object" }
    $obj = $m.Value | ConvertFrom-Json -ErrorAction Stop
    $score = [double]$obj.score
    if ($score -lt 0.0) { $score = 0.0 }
    if ($score -gt 1.0) { $score = 1.0 }
    return @{ score = $score; reason = [string]$obj.reason }
}

function Get-LlmJudgeGrader {
    <# Build a grader scriptblock for the Slice 2 -Grader seam. Heuristic gates first (no
       paid judge call on broken output); a passing output is scored by the judge model.
       Tags the verdict with grader='llm-judge' (or 'heuristic' on gate-fail/fallback). #>
    param(
        [string]$JudgeModel,
        [double]$Threshold = 0.6,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [scriptblock]$JudgeDispatcher
    )
    $jm = $JudgeModel; $th = $Threshold; $fp = $FleetPath; $jd = $JudgeDispatcher
    return {
        param($Capability, $Result)
        $h = Test-RoutingOutputHeuristic -Capability $Capability -Result $Result
        if (-not $h.passed) {
            return @{ passed = $false; score = $h.score; reason = $h.reason; grader = 'heuristic' }
        }
        $model = if ($jm) { $jm } else { Get-JudgeModel -FleetPath $fp }
        if (-not $model) {
            return @{ passed = $h.passed; score = $h.score; reason = "$($h.reason) (judge unavailable: no local model)"; grader = 'heuristic' }
        }
        try {
            $j = Invoke-LlmJudge -Capability $Capability -Output ([string]$Result.stdout) -JudgeModel $model -FleetPath $fp -Dispatcher $jd
            return @{ passed = ($j.score -ge $th); score = $j.score; reason = $j.reason; grader = 'llm-judge' }
        } catch {
            return @{ passed = $h.passed; score = $h.score; reason = "$($h.reason) (judge unavailable: $($_.Exception.Message))"; grader = 'heuristic' }
        }
    }.GetNewClosure()
}
