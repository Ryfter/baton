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

function Get-FindingsJsonBlocks {
    <# Every balanced top-level [...] candidate in a reply, in order (string-aware
       depth scan so brackets inside JSON string values do not split a block). The
       array sibling of conductor-lib's Get-JsonBlocks: needed for providers like
       `codex exec` that echo the prompt (which itself carries the findings SCHEMA
       array AND the plan's own arrays) before the answer — the greedy
       Get-FindingsJsonBlock then spans echo+answer into one invalid blob. A
       mis-scanned candidate simply fails ConvertFrom-Json downstream and is skipped.
       Returns a plain array via .ToArray() — NO unary-comma wrap; callers collect
       with @() (the exact double-wrap bug that bit conductor-lib's Get-JsonBlocks). #>
    param([Parameter(Mandatory)][string]$Raw)
    $blocks = [System.Collections.ArrayList]@()
    $depth = 0; $blockStart = -1; $inStr = $false; $escaped = $false
    for ($i = 0; $i -lt $Raw.Length; $i++) {
        $ch = $Raw[$i]
        if ($inStr) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { if ($depth -gt 0) { $inStr = $true } }
        elseif ($ch -eq '[') { if ($depth -eq 0) { $blockStart = $i }; $depth++ }
        elseif ($ch -eq ']') {
            if ($depth -gt 0) {
                $depth--
                if ($depth -eq 0 -and $blockStart -ge 0) {
                    [void]$blocks.Add($Raw.Substring($blockStart, $i - $blockStart + 1))
                    $blockStart = -1
                }
            }
        }
    }
    return $blocks.ToArray()
}

function Get-ReviewFindings {
    <# Parse one reviewer's output into @{parsed; findings; raw}. Tolerant: accepts a
       bare or prose-embedded JSON array. Each finding normalized to
       @{severity;area;summary}; unknown severities floored to 'minor' (never dropped).
       Unparseable -> parsed=$false, findings=@(). Empty array -> parsed=$true, @().

       Candidate order (mirrors conductor-lib's ConvertTo-PlanObject, adapted to
       arrays): the greedy whole-span block first (the historical fast path — one
       clean/fenced reply; cheap, preserves today's semantics), then the balanced
       [...] blocks LAST-first, because a prompt-echoing reviewer (e.g. `codex exec`,
       which echoes the schema + plan arrays) puts its ANSWER after the echo. The
       first candidate that parses AND clears the schema-echo + shape filters wins.

       Known accepted residual (do NOT try to solve): an echo-ONLY reply — the
       reviewer echoed the prompt and answered nothing — can false-ACCEPT as a clean
       [] via the prompt's own literal "Return []" text forming a bare empty array.
       It fails toward accept on ONE reviewer; the multi-reviewer merge + advisory
       posture bound the blast radius. #>
    param([string]$Output)
    $result = @{ parsed = $false; findings = @(); raw = [string]$Output }
    $text = [string]$Output
    if ([string]::IsNullOrWhiteSpace($text)) { return $result }

    $candidates = [System.Collections.ArrayList]@()
    $greedy = Get-FindingsJsonBlock -Raw $text
    if ($greedy) { [void]$candidates.Add($greedy) }
    $balanced = @(Get-FindingsJsonBlocks -Raw $text)
    for ($bi = $balanced.Count - 1; $bi -ge 0; $bi--) { [void]$candidates.Add($balanced[$bi]) }

    foreach ($block in $candidates) {
        $arr = $null
        try { $arr = $block | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $elements = @($arr)
        # Schema-echo reject: the prompt's placeholder severity "critical|important|minor"
        # — a reviewer that dies after echoing would otherwise hand us the schema as findings.
        $isSchemaEcho = $false
        foreach ($el in $elements) {
            if ($null -ne $el -and (([string]$el.severity) -match '\|')) { $isSchemaEcho = $true; break }
        }
        if ($isSchemaEcho) { continue }
        # Shape validation: a NON-empty candidate survives only if EVERY non-null element
        # is an object exposing BOTH a severity and a non-empty summary (excludes echoed
        # plan fragments like ["t2"] and prose-adjacent brackets like [3]). An EMPTY
        # array [] is a valid clean review and survives.
        $shapeOk = $true
        foreach ($el in $elements) {
            if ($null -eq $el) { continue }
            $names = @($el.PSObject.Properties.Name)
            if (($names -notcontains 'severity') -or ($names -notcontains 'summary') -or `
                [string]::IsNullOrWhiteSpace([string]$el.summary)) { $shapeOk = $false; break }
        }
        if (-not $shapeOk) { continue }
        # Survivor: normalize (unknown severity floored to 'minor', never dropped).
        $norm = [System.Collections.ArrayList]@()
        foreach ($f in $elements) {
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

function Format-PolishBrief {
    <# The must-fix brief for a premium polish pass: critical+important findings,
       agreed-first then severity-desc. 'accept' -> a one-line no-op. #>
    param([Parameter(Mandatory)][hashtable]$Verdict, [array]$MergedFindings)
    if ($Verdict.verdict -eq 'accept') { return 'No polish needed — artifact accepted as-is.' }
    $mustFix = @($MergedFindings | Where-Object { (Get-FindingSeverityRank $_.severity) -ge 2 })
    $ordered = @($mustFix | Sort-Object `
        @{ Expression = { if ($_.agreed) { 0 } else { 1 } } }, `
        @{ Expression = { -(Get-FindingSeverityRank $_.severity) } })
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('POLISH BRIEF — fix the following before this ships as polished:')
    foreach ($f in $ordered) {
        $tag = if ($f.agreed) { 'agreed' } else { 'solo' }
        [void]$sb.AppendLine("  • [$($f.severity)][$tag] $($f.area): $($f.summary)")
    }
    return $sb.ToString().TrimEnd()
}

function Format-GateReport {
    <# Human-readable verdict + counts, findings grouped agreed/solo, unparsed note. #>
    param([Parameter(Mandatory)][hashtable]$Result)
    $v = ([string]$Result.verdict).ToUpperInvariant()
    $c = $Result.counts
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("ACCEPTANCE GATE — verdict: $v  ($($Result.reason))")
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
    return $sb.ToString().TrimEnd()
}

function Build-ReviewPrompt {
    <# Compose one reviewer's instruction: role + strict-JSON findings schema +
       the task + the artifact. The whole prompt rides stdin for stdin:true providers. #>
    param(
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Artifact
    )
    $schema = @'
[
  { "severity": "critical|important|minor",
    "area": "<short area, e.g. correctness, security, style>",
    "summary": "<one line: the specific issue>" }
]
'@
    return @"
You are a strict code/work reviewer. Review the ARTIFACT below against its TASK.
Report real defects only. Respond with ONLY a JSON array matching this schema
exactly — no prose, no markdown fences. Return [] if there are no findings.

Schema:
$schema

Severity: critical = wrong/broken/unsafe; important = should fix before shipping;
minor = nit/style. Be specific in each summary.

## Task
$Task

## Artifact
$Artifact
"@
}

function Invoke-AcceptanceGate {
    <# Run a competitive review of an artifact and return an accept/polish/reject
       verdict with deduped findings + a polish brief. Each reviewer reviews
       INDEPENDENTLY (no cross-talk); reconciliation/verdict are pure. Reviewers
       default to providers claiming the 'review' capability. -Dispatcher injects
       for tests; real path dispatches via Invoke-Fleet. Advisory — never blocks. #>
    param(
        [Parameter(Mandatory)][string]$Artifact,
        [Parameter(Mandatory)][string]$Task,
        [string[]]$Reviewers,
        [string]$RejectAt = 'critical',
        [string]$PolishAt = 'important',
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Dispatcher
    )
    if (-not $Reviewers -or $Reviewers.Count -lt 1) {
        $cands = Select-Capability -Capability review -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
        $Reviewers = @($cands | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.name })
    }
    if (-not $Reviewers -or $Reviewers.Count -lt 1) {
        throw "Invoke-AcceptanceGate: no reviewers configured (grant the 'review' capability to >=1 provider, or pass -Reviewers)."
    }
    $dispatch = {
        param($name, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $name $prompt) }
        return Invoke-Fleet -Name $name -Prompt $prompt -Path $FleetPath -NoJournal
    }
    $prompt  = Build-ReviewPrompt -Task $Task -Artifact $Artifact
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
    $verdict = Get-AcceptanceVerdict -MergedFindings $merge.merged -RejectAt $RejectAt -PolishAt $PolishAt
    if (@($merge.unparsed).Count -ge $Reviewers.Count) {
        $verdict.reason = 'no usable review obtained (fail-open accept)'
    }
    $brief = Format-PolishBrief -Verdict $verdict -MergedFindings $merge.merged
    return [ordered]@{
        verdict = $verdict.verdict; reason = $verdict.reason; counts = $verdict.counts
        findings = $merge.merged; polish_brief = $brief
        reviews = @($reviews | ForEach-Object { @{ reviewer = $_.reviewer; parsed = $_.parsed; count = @($_.findings).Count } })
        unparsed = $merge.unparsed
    }
}
