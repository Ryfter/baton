#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Decision Loop foundation: auto-captured decision records + feedback append + read/filter.

.DESCRIPTION
  Records live at ~/.claude/knowledge/projects/<id>/decisions/d<NNN>-<slug>.md.
  Per-project sequential numbering derived from the filesystem.
  Reuses Plan 3's job-lib.ps1 for Resolve-ProjectId / ConvertTo-JobSlug / Read-CurrentJob.
  Opt-out: ~/.claude/decisions-off (global) or projects/<id>/decisions-off (per-project).
#>

# Dot-source job-lib for shared helpers (Resolve-ProjectId, ConvertTo-JobSlug, Read-CurrentJob).
$script:JobLibPath = Join-Path $PSScriptRoot 'job-lib.ps1'
if (Test-Path $script:JobLibPath) { . $script:JobLibPath }

$script:DefaultKbRoot = (Join-Path $HOME '.claude/knowledge')
$script:DefaultOptOut = (Join-Path $HOME '.claude/decisions-off')

function Get-NextDecisionId {
    <# Scan ProjectDecisionsDir for the highest dNNN-*.md and return the next id. #>
    param([Parameter(Mandatory)][string]$ProjectDecisionsDir)
    if (-not (Test-Path $ProjectDecisionsDir)) { return 'd001' }
    $max = 0
    foreach ($f in Get-ChildItem -Path $ProjectDecisionsDir -Filter 'd*.md' -ErrorAction SilentlyContinue) {
        if ($f.Name -match '^d(\d{3,})') {
            $n = [int]$matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ('d{0:D3}' -f ($max + 1))
}

function Test-DecisionsOptOut {
    <# Returns $true if any opt-out marker is present (global or per-project). #>
    param(
        [string]$OptOutPath = $script:DefaultOptOut,
        [string]$ProjectOptOutPath
    )
    if (Test-Path $OptOutPath) { return $true }
    if ($ProjectOptOutPath -and (Test-Path $ProjectOptOutPath)) { return $true }
    return $false
}

function Add-DecisionRecord {
    <# Write a structured decision record. Returns @{ id; path } or $null if opted-out. #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Chosen,
        [Parameter(Mandatory)][string[]]$Alternatives,
        [Parameter(Mandatory)][string]$Rationale,
        [Parameter(Mandatory)][ValidateSet('high','med','low')][string]$Confidence,
        [Parameter(Mandatory)][string]$RevisitIf,
        [string]$Project,
        [string]$Job,
        [string]$Phase,
        [string]$KbRoot = $script:DefaultKbRoot,
        [string]$OptOutPath = $script:DefaultOptOut
    )

    # Resolve project: explicit arg → Plan 3 Resolve-ProjectId → fallback "_uncategorized"
    if (-not $Project) {
        if (Get-Command Resolve-ProjectId -ErrorAction SilentlyContinue) {
            $Project = Resolve-ProjectId
        }
        if (-not $Project) { $Project = '_uncategorized' }
    }

    $projDir = Join-Path $KbRoot "projects/$Project"
    $projOptOut = Join-Path $projDir 'decisions-off'

    # Opt-out check BEFORE id resolution and dir creation — opting out writes nothing
    if (Test-DecisionsOptOut -OptOutPath $OptOutPath -ProjectOptOutPath $projOptOut) {
        return $null
    }

    $decDir = Join-Path $projDir 'decisions'
    if (-not (Test-Path $decDir)) { New-Item -ItemType Directory -Force -Path $decDir | Out-Null }

    $id = Get-NextDecisionId -ProjectDecisionsDir $decDir
    $slug = if (Get-Command ConvertTo-JobSlug -ErrorAction SilentlyContinue) {
        ConvertTo-JobSlug $Title
    } else {
        # Fallback when job-lib isn't dot-sourced. Compute the slug first, then trim
        # using the slug's own length (NOT $Title.Length — special-char-heavy titles
        # produce shorter slugs and would crash Substring).
        $s = ($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        if ([string]::IsNullOrEmpty($s)) { $s = 'untitled' }
        $s.Substring(0, [Math]::Min(40, $s.Length))
    }
    $path = Join-Path $decDir "$id-$slug.md"

    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $altLines = ($Alternatives | ForEach-Object { "- $_" }) -join "`n"

    # Quote revisit-if so YAML doesn't choke on colons/special chars
    $revisitEscaped = $RevisitIf -replace '"', '\"'

    $jobLine   = if ($Job)   { "job: $Job" }     else { "job: null" }
    $phaseLine = if ($Phase) { "phase: $Phase" } else { "phase: null" }

    $content = @"
---
id: $id
timestamp: $ts
project: $Project
$jobLine
$phaseLine
status: active
confidence: $Confidence
revisit-if: "$revisitEscaped"
flag: null
---

# $Title

**Chosen:** $Chosen

**Alternatives:**
$altLines

**Rationale:** $Rationale

## Feedback
"@

    Set-Content -Path $path -Value $content -Encoding utf8NoBOM
    return @{ id = $id; path = $path }
}

function Find-DecisionRecordPath {
    <# Return the .md path for a given decision id within a project, or $null. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Project,
        [string]$KbRoot = $script:DefaultKbRoot
    )
    $decDir = Join-Path $KbRoot "projects/$Project/decisions"
    if (-not (Test-Path $decDir)) { return $null }
    $match = Get-ChildItem -Path $decDir -Filter "$Id-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) { return $match.FullName }
    return $null
}

function Append-DecisionFeedback {
    <# Append a feedback entry to a record's ## Feedback section, optionally setting flag. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('worked','didnt','mixed')][string]$Outcome = 'worked',
        [Parameter(Mandatory)][string]$Author,
        [string]$KbRoot = $script:DefaultKbRoot
    )
    $path = Find-DecisionRecordPath -Id $Id -Project $Project -KbRoot $KbRoot
    if (-not $path) { throw "No decision record found for id '$Id' in project '$Project'." }

    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    # Sanitize text: collapse newlines + escape pipes (matches Plan 3 lesson conventions)
    $safe = ($Text -replace '\|', '¦' -replace "`r?`n", ' ').Trim()
    $entry = "$ts | $Author | outcome:$Outcome | $safe"
    Add-Content -Path $path -Value $entry -Encoding utf8NoBOM

    # On negative outcome, flip front-matter flag (line-by-line edit; YAML stays valid)
    if ($Outcome -in @('didnt','mixed')) {
        $lines = Get-Content $path
        $updated = $lines | ForEach-Object {
            if ($_ -match '^flag:\s+null\s*$') { 'flag: review-needed' } else { $_ }
        }
        Set-Content -Path $path -Value ($updated -join "`n") -Encoding utf8NoBOM
    }
}

function Read-Decisions {
    <# List decision records for a project, optionally filtered by -Job. Returns lightweight objects. #>
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$Job,
        [string]$KbRoot = $script:DefaultKbRoot
    )
    $decDir = Join-Path $KbRoot "projects/$Project/decisions"
    if (-not (Test-Path $decDir)) { return @() }
    $out = @()
    foreach ($f in (Get-ChildItem -Path $decDir -Filter 'd*.md' -ErrorAction SilentlyContinue)) {
        $raw = Get-Content $f.FullName -Raw
        $id    = if ($raw -match '(?m)^id:\s+(d\d{3})')          { $matches[1] } else { $f.BaseName }
        $title = if ($raw -match '(?m)^#\s+(.+)$')                { $matches[1].Trim() } else { '(no title)' }
        $conf  = if ($raw -match '(?m)^confidence:\s+(\w+)')      { $matches[1] } else { 'unknown' }
        $flag  = if ($raw -match '(?m)^flag:\s+(\S+)')            { $matches[1] } else { 'null' }
        $rjob  = if ($raw -match '(?m)^job:\s+(\S+)')             { $matches[1] } else { 'null' }
        if ($Job -and $rjob -ne $Job) { continue }
        $out += [pscustomobject]@{
            id = $id; title = $title; confidence = $conf; flag = $flag; job = $rjob; path = $f.FullName
        }
    }
    return $out
}
