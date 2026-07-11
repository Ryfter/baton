#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Plan Gate (d080, Slice 1). Runs a competitive review of a plan's task-DAG
  (>=2 reviewers, independent) BEFORE any labor runs, and emits an
  accept/revise/reject verdict with deduped, severity-weighted findings + a
  revise brief. Sibling of the Acceptance Gate (gate-lib.ps1), which reviews
  finished WORK instead of a not-yet-executed plan. Advisory — never blocks
  by itself; fail-opens (never throws) when the plan-review roster is
  understaffed, because a missing peer must never freeze the Conductor.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-plan-gate.ps1 wraps
  it for /baton:plan-gate. Reuses gate-lib's pure findings helpers as-is
  (Get-FindingSeverityRank, Get-FindingsJsonBlock, Get-ReviewFindings,
  Get-FindingKey, Merge-ReviewFindings) — no second JSON findings parser.
  gate-lib itself dot-sources baton-home + routing-lib, which brings
  Select-Capability and, via fleet-lib, Invoke-Fleet.
.NOTES
  See docs/superpowers/specs/2026-07-10-plan-gate-design.md (d-pg-1..6).
#>
. "$PSScriptRoot/gate-lib.ps1"   # Get-FindingSeverityRank, Get-ReviewFindings, Get-FindingKey,
                                  # Merge-ReviewFindings (+ transitively: baton-home, routing-lib,
                                  # Select-Capability, Invoke-Fleet)

function Get-PlanReviewVerdict {
    <# Same mechanics as gate-lib's Get-AcceptanceVerdict, but the middle
       verdict is 'revise' (not 'polish') — this gate reviews a plan about
       to be executed, not finished work. any >=RejectAt -> reject; else
       any >=ReviseAt -> revise; else accept. Counts each tier. #>
    param(
        [array]$MergedFindings,
        [string]$RejectAt = 'critical',
        [string]$ReviseAt = 'important'
    )
    $counts = @{ critical = 0; important = 0; minor = 0 }
    $maxRank = 0
    foreach ($f in @($MergedFindings)) {
        $r = Get-FindingSeverityRank $f.severity
        if ($r -gt $maxRank) { $maxRank = $r }
        switch ($r) { 3 { $counts.critical++ } 2 { $counts.important++ } 1 { $counts.minor++ } }
    }
    $rejRank = Get-FindingSeverityRank $RejectAt
    $revRank = Get-FindingSeverityRank $ReviseAt
    if ($maxRank -ge $rejRank)     { $verdict = 'reject' }
    elseif ($maxRank -ge $revRank) { $verdict = 'revise' }
    else                            { $verdict = 'accept' }
    $reason = switch ($verdict) {
        'reject' { "$($counts.critical) critical finding(s)" }
        'revise' { "$($counts.important) important finding(s)" }
        'accept' { if ($counts.minor -gt 0) { "$($counts.minor) minor finding(s), none blocking" } else { 'no findings' } }
    }
    return @{ verdict = $verdict; reason = $reason; counts = $counts }
}

function Format-ReviseBrief {
    <# Plan analogue of gate-lib's Format-PolishBrief: critical+important
       findings, agreed-first then severity-desc. 'accept' -> a one-line
       no-op. #>
    param([Parameter(Mandatory)][hashtable]$Verdict, [array]$MergedFindings)
    if ($Verdict.verdict -eq 'accept') { return 'No revision needed — plan accepted as-is.' }
    $mustFix = @($MergedFindings | Where-Object { (Get-FindingSeverityRank $_.severity) -ge 2 })
    $ordered = @($mustFix | Sort-Object `
        @{ Expression = { if ($_.agreed) { 0 } else { 1 } } }, `
        @{ Expression = { -(Get-FindingSeverityRank $_.severity) } })
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('REVISE BRIEF — address the following before the plan runs:')
    foreach ($f in $ordered) {
        $tag = if ($f.agreed) { 'agreed' } else { 'solo' }
        [void]$sb.AppendLine("  • [$($f.severity)][$tag] $($f.area): $($f.summary)")
    }
    return $sb.ToString().TrimEnd()
}

function Format-PlanGateReport {
    <# Human-readable verdict + counts, findings grouped agreed/solo, unparsed
       note. Mirror of gate-lib's Format-GateReport, plus a fail-open note
       when the roster was understaffed. #>
    param([Parameter(Mandatory)][hashtable]$Result)
    $v = ([string]$Result.verdict).ToUpperInvariant()
    $c = $Result.counts
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("PLAN GATE — verdict: $v  ($($Result.reason))")
    [void]$sb.AppendLine("Findings: $($c.critical) critical, $($c.important) important, $($c.minor) minor")
    $agreed = @($Result.findings | Where-Object { $_.agreed })
    $solo   = @($Result.findings | Where-Object { -not $_.agreed })
    if ($agreed.Count) {
        [void]$sb.AppendLine('Agreed (raised by multiple reviewers):')
        foreach ($f in $agreed) { [void]$sb.AppendLine("  • [$($f.severity)] $($f.area): $($f.summary)") }
    }
    if ($solo.Count) {
        [void]$sb.AppendLine('Solo (one reviewer):')
        foreach ($f in $solo) { [void]$sb.AppendLine("  • [$($f.severity)] $($f.area): $($f.summary) (by $($f.raised_by -join ', '))") }
    }
    if ($Result.unparsed -and @($Result.unparsed).Count) {
        [void]$sb.AppendLine("Note: $((@($Result.unparsed)) -join ', ') returned no usable review.")
    }
    if ($Result.fail_open) {
        [void]$sb.AppendLine('Note: gate failed open (understaffed plan-review roster) — plan NOT peer-reviewed.')
    }
    return $sb.ToString().TrimEnd()
}

function Build-PlanReviewPrompt {
    <# Compose one reviewer's instruction: role + strict-JSON findings schema
       + the goal + the plan DAG. Built with a here-string; $Goal/$PlanJson
       are interpolated (never regex-substituted — house rule: no regex
       substitution of untrusted text). #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [Parameter(Mandatory)][string]$PlanJson
    )
    $schema = @'
[
  { "severity": "critical|important|minor",
    "area": "scope|ordering|cost|risk|missing-task|overbuild|capability|reversibility",
    "summary": "<one line: the specific issue>" }
]
'@
    return @"
You are a strict plan reviewer for an autonomous coding conductor. The plan
below is a task DAG that is about to be EXECUTED by fleet models — you are
reviewing the PLAN, not finished work. Report real defects only. Respond
with ONLY a JSON array matching this schema exactly — no prose, no markdown
fences. Return [] if the plan is sound.

Schema:
$schema

Severity: critical = the plan will fail, damage something, or build the
wrong thing; important = the plan should be revised before running; minor =
nit. Be specific in each summary.

## Goal
$Goal

## Plan (JSON)
$PlanJson
"@
}

function Invoke-PlanGate {
    <# Run a competitive review of a plan (task DAG) and return an
       accept/revise/reject verdict with deduped findings + a revise brief.
       Each reviewer reviews INDEPENDENTLY (no cross-talk); reconciliation
       and verdict are pure. Reviewers default to providers claiming the
       'plan-review' capability. -Dispatcher injects for tests; real path
       dispatches via Invoke-Fleet. Fail-open, NEVER throws: fewer than 2
       resolved reviewers returns an accept result flagged fail_open with
       zero dispatch/spend — a missing Grok CLI must never freeze the
       Conductor (contrast: Invoke-AcceptanceGate throws at <1 reviewer). #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [Parameter(Mandatory)][string]$PlanJson,
        [string[]]$Reviewers,
        [string]$RejectAt = 'critical',
        [string]$ReviseAt = 'important',
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Dispatcher
    )
    if (-not $Reviewers -or $Reviewers.Count -lt 1) {
        $cands = Select-Capability -Capability plan-review -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
        $Reviewers = @($cands | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.name })
    }
    # Dedupe case-insensitively BEFORE the <2 understaffed check: `-Reviewers codex,codex`
    # is ONE reviewer posing as a pair — it must fail-open as understaffed, not pretend to
    # be a competitive review. NB: Select-Object -Unique is CASE-SENSITIVE in PS7 (no
    # -CaseSensitive knob exists), so an OrdinalIgnoreCase HashSet does the case-insensitive
    # dedupe while preserving order + first-seen casing (Add() is true only on first sight).
    $seenReviewers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Reviewers = @($Reviewers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Where-Object { $seenReviewers.Add($_) })
    if (@($Reviewers).Count -lt 2) {
        return [ordered]@{
            verdict = 'accept'; reason = 'understaffed plan-review roster (fewer than 2 reviewers) — fail-open'
            counts = @{ critical = 0; important = 0; minor = 0 }
            findings = @(); revise_brief = 'No revision needed — plan accepted as-is.'
            reviews = @(); unparsed = @(); fail_open = $true; reviewers = @($Reviewers)
        }
    }
    $dispatch = {
        param($name, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $name $prompt) }
        return Invoke-Fleet -Name $name -Prompt $prompt -Path $FleetPath -NoJournal
    }
    $prompt  = Build-PlanReviewPrompt -Goal $Goal -PlanJson $PlanJson
    $reviews = [System.Collections.ArrayList]@()
    foreach ($r in $Reviewers) {
        $pf = @{ reviewer = $r; parsed = $false; findings = @() }
        try {
            $res = & $dispatch $r $prompt
            if ([int]$res.exit_code -eq 0) {
                $parsed = Get-ReviewFindings -Output ([string]$res.stdout)
                $pf.parsed   = $parsed.parsed
                $pf.findings = $parsed.findings
            }
        } catch {
            Write-Debug "reviewer $r failed: $($_.Exception.Message)"
        }
        [void]$reviews.Add($pf)
    }
    $merge   = Merge-ReviewFindings -Reviews $reviews.ToArray()
    $verdict = Get-PlanReviewVerdict -MergedFindings $merge.merged -RejectAt $RejectAt -ReviseAt $ReviseAt
    $failOpen = $false
    if (@($merge.unparsed).Count -ge $Reviewers.Count) {
        $verdict.reason = 'no usable review obtained (fail-open accept)'
        $failOpen = $true
    }
    $brief = Format-ReviseBrief -Verdict $verdict -MergedFindings $merge.merged
    return [ordered]@{
        verdict = $verdict.verdict; reason = $verdict.reason; counts = $verdict.counts
        findings = $merge.merged; revise_brief = $brief
        reviews = @($reviews | ForEach-Object { @{ reviewer = $_.reviewer; parsed = $_.parsed; count = @($_.findings).Count } })
        unparsed = $merge.unparsed; fail_open = $failOpen; reviewers = @($Reviewers)
    }
}
