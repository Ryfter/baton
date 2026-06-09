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

$script:DefaultRatingsPath = (Join-Path $HOME '.claude/knowledge/universal/routing-ratings.jsonl')

function Read-JsonlRows {
    <# Robust JSONL reader: missing path -> empty; malformed lines skipped. Returns object[]. #>
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
    return ([object[]]@($rows))
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

function Get-RoutingStats {
    <# Per-(capability,candidate) signal stats from ratings + journal. Internal. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath
    )
    # User ratings
    $rt = Get-CapabilityRatings -Capability $Capability -Candidate $Candidate -RatingsPath $RatingsPath
    $nu = @($rt).Count
    $gu = @($rt | Where-Object { $_.rating -eq 'good' }).Count
    $ru = if ($nu -gt 0) { [double]$gu / $nu } else { 0.0 }

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
        judge     = @{ rate = $rj; n = [int]$nj }
        heuristic = @{ rate = $rh; n = [int]$nh }
    }
}

function Get-CapabilityQualityDetail {
    <# Learned quality + its provenance. Pseudo-count Bayesian blend; shrinks to -Prior. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [double]$Prior = 0.5
    )
    $s  = Get-RoutingStats -Capability $Capability -Candidate $Candidate -JournalPath $JournalPath -RatingsPath $RatingsPath
    $k  = 2.0; $Wu = 1.0; $Wj = 0.5; $Wh = 0.25
    $numer = ($Prior * $k) + ($Wu * $s.user.n * $s.user.rate) + ($Wj * $s.judge.n * $s.judge.rate) + ($Wh * $s.heuristic.n * $s.heuristic.rate)
    $denom = $k + ($Wu * $s.user.n) + ($Wj * $s.judge.n) + ($Wh * $s.heuristic.n)
    $q = if ($denom -gt 0) { $numer / $denom } else { $Prior }
    if ($q -lt 0.0) { $q = 0.0 }
    if ($q -gt 1.0) { $q = 1.0 }
    return @{
        quality   = [double]$q
        prior     = [double]$Prior
        user      = $s.user
        judge     = $s.judge
        heuristic = $s.heuristic
    }
}

function Get-CapabilityQuality {
    <# Learned quality in [0,1] for a (capability, candidate). Convenience wrapper. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [double]$Prior = 0.5
    )
    return (Get-CapabilityQualityDetail -Capability $Capability -Candidate $Candidate -JournalPath $JournalPath -RatingsPath $RatingsPath -Prior $Prior).quality
}

function Get-LastRoutedAttempt {
    <# The most recent PASSING attempt in the journal — the winner the user last saw.
       Returns $null when no passing attempt exists. #>
    param([string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'))
    $rows = @(Read-JsonlRows -Path $JournalPath)
    for ($i = $rows.Count - 1; $i -ge 0; $i--) {
        if ($rows[$i].passed -eq $true) { return $rows[$i] }
    }
    return $null
}
