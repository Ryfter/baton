#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Acceptance/Polish Gate (Sprint 7). Runs a competitive review of a finished work
  artifact (>=2 reviewers, independent) and emits an accept/polish/reject verdict
  with deduped, severity-weighted findings + a polish brief. Advisory — never blocks.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-gate.ps1 wraps it for
  /baton:gate. routing-lib brings Select-Capability and, via fleet-lib, Invoke-Fleet.
.NOTES
  See docs/superpowers/specs/2026-06-20-acceptance-polish-gate-sprint7-design.md (d-ag-1..5).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability (+ fleet-lib: Invoke-Fleet)

function Get-FindingSeverityRank {
    <# critical=3, important=2, minor=1, unknown/absent=0. Case-insensitive. #>
    param([string]$Severity)
    switch (([string]$Severity).Trim().ToLowerInvariant()) {
        'critical'  { return 3 }
        'important' { return 2 }
        'minor'     { return 1 }
        default     { return 0 }
    }
}

function Get-FindingsJsonBlock {
    <# Extract the JSON array from a reply that may be fenced or prose-wrapped:
       first '[' to last ']'. Returns '' when none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open  = $Raw.IndexOf('[')
    $close = $Raw.LastIndexOf(']')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function Get-ReviewFindings {
    <# Parse one reviewer's output into @{parsed; findings; raw}. Tolerant: accepts a
       bare or prose-embedded JSON array. Each finding normalized to
       @{severity;area;summary}; unknown severities floored to 'minor' (never dropped).
       Unparseable -> parsed=$false, findings=@(). Empty array -> parsed=$true, @(). #>
    param([string]$Output)
    $result = @{ parsed = $false; findings = @(); raw = [string]$Output }
    $text = [string]$Output
    if ([string]::IsNullOrWhiteSpace($text)) { return $result }
    $block = Get-FindingsJsonBlock -Raw $text
    if (-not $block) { return $result }
    try { $arr = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $result }
    $norm = [System.Collections.ArrayList]@()
    foreach ($f in @($arr)) {
        if ($null -eq $f) { continue }
        $sev = ([string]$f.severity).Trim().ToLowerInvariant()
        if ((Get-FindingSeverityRank $sev) -eq 0) { $sev = 'minor' }  # unknown -> floor, never drop
        [void]$norm.Add(@{
            severity = $sev
            area     = ([string]$f.area).Trim()
            summary  = ([string]$f.summary).Trim()
        })
    }
    $result.parsed = $true
    $result.findings = @($norm.ToArray())
    return $result
}

function Get-FindingKey {
    <# Dedupe key: lowercased, whitespace-collapsed area|summary. Deliberately
       conservative — divergent wordings stay separate (solo) rather than false-merge. #>
    param([Parameter(Mandatory)][hashtable]$Finding)
    $a = (([string]$Finding.area)    -replace '\s+',' ').Trim().ToLowerInvariant()
    $s = (([string]$Finding.summary) -replace '\s+',' ').Trim().ToLowerInvariant()
    return "$a|$s"
}

function Merge-ReviewFindings {
    <# Reconcile per-reviewer parse results into one deduped set. Input items:
       @{reviewer;parsed;findings}. Same key from >=2 reviewers -> one merged finding,
       higher severity kept, agreed=$true. Unparsed reviewers collected by name. #>
    param([array]$Reviews)
    $unparsed = [System.Collections.ArrayList]@()
    $byKey = [ordered]@{}
    foreach ($rv in @($Reviews)) {
        if ($null -eq $rv) { continue }
        if (-not $rv.parsed) { [void]$unparsed.Add([string]$rv.reviewer); continue }
        foreach ($f in @($rv.findings)) {
            $key = Get-FindingKey -Finding $f
            if ($byKey.Contains($key)) {
                $m = $byKey[$key]
                if ((Get-FindingSeverityRank $f.severity) -gt (Get-FindingSeverityRank $m.severity)) {
                    $m.severity = $f.severity
                }
                if ($m.raised_by -notcontains $rv.reviewer) { $m.raised_by += [string]$rv.reviewer }
                $m.agreed = ($m.raised_by.Count -ge 2)
            } else {
                $byKey[$key] = @{
                    severity  = $f.severity; area = $f.area; summary = $f.summary
                    raised_by = @([string]$rv.reviewer); agreed = $false
                }
            }
        }
    }
    return @{ merged = @($byKey.Values); unparsed = @($unparsed.ToArray()) }
}

function Get-AcceptanceVerdict {
    <# Severity-driven verdict over the merged set. any >=RejectAt -> reject;
       else any >=PolishAt -> polish; else accept. Counts each tier. #>
    param(
        [array]$MergedFindings,
        [string]$RejectAt = 'critical',
        [string]$PolishAt = 'important'
    )
    $counts = @{ critical = 0; important = 0; minor = 0 }
    $maxRank = 0
    foreach ($f in @($MergedFindings)) {
        $r = Get-FindingSeverityRank $f.severity
        if ($r -gt $maxRank) { $maxRank = $r }
        switch ($r) { 3 { $counts.critical++ } 2 { $counts.important++ } 1 { $counts.minor++ } }
    }
    $rejRank = Get-FindingSeverityRank $RejectAt
    $polRank = Get-FindingSeverityRank $PolishAt
    if ($maxRank -ge $rejRank)     { $verdict = 'reject' }
    elseif ($maxRank -ge $polRank) { $verdict = 'polish' }
    else                           { $verdict = 'accept' }
    $reason = switch ($verdict) {
        'reject' { "$($counts.critical) critical finding(s)" }
        'polish' { "$($counts.important) important finding(s)" }
        'accept' { if ($counts.minor -gt 0) { "$($counts.minor) minor finding(s), none blocking" } else { 'no findings' } }
    }
    return @{ verdict = $verdict; reason = $reason; counts = $counts }
}
