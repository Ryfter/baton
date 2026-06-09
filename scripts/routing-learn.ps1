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
