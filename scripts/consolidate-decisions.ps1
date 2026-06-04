#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Distill decision records + feedback into two-layer guidance docs.

.DESCRIPTION
  For each project in $KbRoot/projects/:
    - Read its decision records.
    - Group by chosen-pattern (a stable signature derived from title+chosen).
    - Write projects/<id>/decision-guidance.md with: Established patterns
      (positive outcomes), Known mistakes (negative outcomes), Open/under-feedback,
      Deviations from universal.
  Then: promote any pattern observed in >=2 projects with at least one
  outcome:worked feedback per project to universal/decision-guidance.md.
  Mark consolidated records with a footer comment (idempotency).
#>

param(
    [string]$KbRoot = (Join-Path $HOME '.claude/knowledge')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'decisions-lib.ps1')

$projectsRoot = Join-Path $KbRoot 'projects'
$universalGuidance = Join-Path $KbRoot 'universal/decision-guidance.md'
if (-not (Test-Path (Split-Path $universalGuidance -Parent))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $universalGuidance -Parent) | Out-Null
}
if (-not (Test-Path $universalGuidance)) {
    Set-Content -Path $universalGuidance -Value "# Universal Decision Guidance`n`n" -Encoding utf8NoBOM
}

$today = Get-Date -Format 'yyyy-MM-dd'

function Get-RecordSignature {
    <# A coarse signature for cross-project pattern matching: lowercased title + chosen. #>
    param([string]$Title, [string]$Chosen)
    $sig = "$Title|$Chosen".ToLowerInvariant()
    $sig = ($sig -replace '\s+', ' ').Trim()
    return $sig
}

function Read-RecordDetail {
    <# Parse a record file into a hashtable with id, title, chosen, alternatives, rationale, confidence,
       feedback-outcomes (string[]), already-consolidated (bool), signature, path. #>
    param([string]$Path)
    $raw = Get-Content $Path -Raw
    $id        = if ($raw -match '(?m)^id:\s+(d\d{3})')           { $matches[1] } else { 'd???' }
    $title     = if ($raw -match '(?m)^#\s+(.+)$')                 { $matches[1].Trim() } else { '(no title)' }
    $chosen    = if ($raw -match '\*\*Chosen:\*\*\s+(.+?)\r?\n')   { $matches[1].Trim() } else { '' }
    $rationale = if ($raw -match '\*\*Rationale:\*\*\s+(.+?)\r?\n') { $matches[1].Trim() } else { '' }
    $conf      = if ($raw -match '(?m)^confidence:\s+(\w+)')        { $matches[1] } else { 'unknown' }
    $already   = ($raw -match '<!-- consolidated \d{4}-\d{2}-\d{2} -->')

    # Extract outcome:<x> from any feedback line
    $outcomes = @()
    foreach ($m in [regex]::Matches($raw, 'outcome:(worked|didnt|mixed)')) {
        $outcomes += $m.Groups[1].Value
    }

    return @{
        id = $id; title = $title; chosen = $chosen; rationale = $rationale
        confidence = $conf; outcomes = $outcomes; alreadyConsolidated = $already
        signature = (Get-RecordSignature -Title $title -Chosen $chosen); path = $Path
    }
}

if (-not (Test-Path $projectsRoot)) {
    Write-Host "No projects to consolidate." -ForegroundColor Yellow
    exit 0
}

# --- Pass 1: build per-project bucket + per-signature cross-project map ---
$projectData = @{}              # project -> @{ records=@(); guidancePath; recordsDir }
$signatureMap = @{}             # signature -> @{ projects = [hashtable]; example = $record; positiveProjects = [hashtable] }

foreach ($projDir in Get-ChildItem -Path $projectsRoot -Directory) {
    $projName = $projDir.Name
    $decDir = Join-Path $projDir.FullName 'decisions'
    $guide = Join-Path $projDir.FullName 'decision-guidance.md'
    if (-not (Test-Path $decDir)) { continue }
    $records = @()
    foreach ($f in (Get-ChildItem -Path $decDir -Filter 'd*.md' -ErrorAction SilentlyContinue)) {
        $rec = Read-RecordDetail -Path $f.FullName
        $records += $rec
        if (-not $signatureMap.ContainsKey($rec.signature)) {
            $signatureMap[$rec.signature] = @{ projects = @{}; example = $rec; positiveProjects = @{} }
        }
        $signatureMap[$rec.signature].projects[$projName] = $true
        if ($rec.outcomes -contains 'worked') {
            $signatureMap[$rec.signature].positiveProjects[$projName] = $true
        }
    }
    $projectData[$projName] = @{ records = $records; guidancePath = $guide; recordsDir = $decDir }
}

# --- Pass 2: write per-project guidance ---
foreach ($projName in $projectData.Keys) {
    $pd = $projectData[$projName]
    $established = @()       # records with worked outcome
    $mistakes = @()          # records with didnt/mixed outcome
    $open = @()              # records with no outcome yet

    foreach ($rec in $pd.records) {
        if ($rec.outcomes -contains 'worked') {
            $established += "- **$($rec.title)** — *chose:* $($rec.chosen) ($($rec.id), conf:$($rec.confidence))"
        } elseif (($rec.outcomes -contains 'didnt') -or ($rec.outcomes -contains 'mixed')) {
            $mistakes += "- **$($rec.title)** — *chose:* $($rec.chosen) ($($rec.id), conf:$($rec.confidence))"
        } else {
            $open += "- **$($rec.title)** — $($rec.id), conf:$($rec.confidence)"
        }
    }

    $establishedSection = if ($established.Count -gt 0) { $established -join "`n" } else { '_None yet._' }
    $mistakesSection    = if ($mistakes.Count -gt 0)    { $mistakes -join "`n" }    else { '_None yet._' }
    $openSection        = if ($open.Count -gt 0)        { $open -join "`n" }        else { '_None._' }

    # Deviations section is a stub for now (filled by /project-init or manual edit).
    $deviationsHeader = "## Deviations from universal`n`n_None recorded yet — edit this section to log per-project departures from universal guidance, with their reasons._"

    $body = @"
# Decision guidance — $projName

_Last consolidated: ${today}_

## Established patterns

$establishedSection

## Known mistakes

$mistakesSection

## Open / under-feedback

$openSection

$deviationsHeader
"@

    Set-Content -Path $pd.guidancePath -Value $body -Encoding utf8NoBOM
}

# --- Pass 3: promote cross-project patterns to universal ---
$existingUniversal = Get-Content $universalGuidance -Raw -ErrorAction SilentlyContinue
if (-not $existingUniversal) { $existingUniversal = "# Universal Decision Guidance`n`n" }

foreach ($sig in $signatureMap.Keys) {
    $entry = $signatureMap[$sig]
    if ($entry.positiveProjects.Count -lt 2) { continue }  # threshold: >=2 projects with positive feedback
    $line = "- **$($entry.example.title)** — *chose:* $($entry.example.chosen). Observed with positive feedback in: $($entry.positiveProjects.Keys -join ', ')."
    # Idempotency: skip if already present (match by title to avoid re-adding on second run)
    if ($existingUniversal -match [regex]::Escape($entry.example.title)) { continue }
    $existingUniversal = $existingUniversal.TrimEnd() + "`n" + $line + "`n"
}
Set-Content -Path $universalGuidance -Value $existingUniversal -Encoding utf8NoBOM

# --- Pass 4: mark records consolidated (idempotency) ---
foreach ($projName in $projectData.Keys) {
    foreach ($rec in $projectData[$projName].records) {
        if ($rec.alreadyConsolidated) { continue }
        Add-Content -Path $rec.path -Value "`n<!-- consolidated $today -->" -Encoding utf8NoBOM
    }
}

Write-Host "Decision consolidation complete." -ForegroundColor Green
