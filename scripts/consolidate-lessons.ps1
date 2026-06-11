#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Walk job lessons.md files, route entries to KB files by category + scope,
  mark source entries consolidated. Idempotent.

.DESCRIPTION
  For each job under $JobsRoot:
    For each lesson line not already marked '✓ consolidated':
      Resolve scope (default per category, override via line metadata if present).
      Append to the appropriate KB file with timestamp + [job-id] + text.
      Mark source line consolidated.
#>

param(
    [string]$JobsRoot = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'jobs' } else { Join-Path $HOME '.baton/jobs' }),
    [string]$KbRoot   = (Join-Path $HOME '.claude/knowledge')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'job-lib.ps1')

if (-not (Test-Path $JobsRoot)) { Write-Host "No jobs dir."; exit 0 }
if (-not (Test-Path $KbRoot))   { New-Item -ItemType Directory -Force -Path $KbRoot | Out-Null }
New-Item -ItemType Directory -Force -Path (Join-Path $KbRoot 'universal'), (Join-Path $KbRoot 'projects') | Out-Null

function Get-KbPath {
    param([string]$Category, [string]$Scope, [string]$Project, [string]$KbRoot)
    switch ($Category) {
        'routing'      { return Join-Path $KbRoot 'universal/routing.md' }
        'user-pref'    { return Join-Path $KbRoot 'universal/user-prefs.md' }
        'reasoning'    { return Join-Path $KbRoot 'universal/reasoning.md' }
        'mistake'      {
            if ($Scope -eq 'universal') { return Join-Path $KbRoot 'universal/mistakes.md' }
            return Join-Path $KbRoot "projects/$Project/mistakes.md"
        }
        'winner'       {
            if ($Scope -eq 'universal') { return Join-Path $KbRoot 'universal/winners.md' }
            return Join-Path $KbRoot "projects/$Project/winners.md"
        }
        'convention'   { return Join-Path $KbRoot "projects/$Project/conventions.md" }
        'decision'     { return Join-Path $KbRoot "projects/$Project/decisions.md" }
        'architecture' { return Join-Path $KbRoot "projects/$Project/architecture.md" }
        'knowledge'    {
            if ($Scope -eq 'universal') { return Join-Path $KbRoot 'universal/topics/general.md' }
            return Join-Path $KbRoot "projects/$Project/topics/general.md"
        }
        default { return $null }
    }
}

$consolidatedDate = Get-Date -Format 'yyyy-MM-dd'
# Supports both old format: ts | cat | "text"
# and new format:           ts | cat | scope | "text"
# The scope group is optional; if absent, Get-LessonDefaultScope is used.
$lessonLineRe = '^(?<ts>\d{4}-\d{2}-\d{2}T[\d:+-]+)\s*\|\s*(?<cat>[a-z-]+)\s*\|\s*(?:(?<scope>universal|project)\s*\|\s*)?"(?<text>.+?)"\s*(?<consolidated>✓ consolidated [\d-]+)?\s*$'
$alreadyDoneRe = '✓ consolidated'

foreach ($jobDir in Get-ChildItem -Path $JobsRoot -Directory) {
    $mani = Read-Manifest -JobDir $jobDir.FullName
    if (-not $mani) { continue }
    $project = $mani.project
    $lessonsPath = Join-Path $jobDir.FullName 'lessons.md'
    if (-not (Test-Path $lessonsPath)) { continue }

    $rawLines = Get-Content $lessonsPath
    $newLines = @()
    $changed = $false

    foreach ($line in $rawLines) {
        # Skip lines already consolidated
        if ($line -match $alreadyDoneRe) {
            $newLines += $line
            continue
        }
        $m = [regex]::Match($line, $lessonLineRe)
        if (-not $m.Success) {
            $newLines += $line
            continue
        }
        $cat = $m.Groups['cat'].Value
        if (-not (Test-LessonCategory $cat)) {
            $newLines += $line
            continue
        }
        $text = $m.Groups['text'].Value
        # Prefer explicit scope field (new format); fall back to category default (old format).
        $scope = if ($m.Groups['scope'].Success -and $m.Groups['scope'].Value) {
            $m.Groups['scope'].Value
        } else {
            Get-LessonDefaultScope $cat
        }
        # For project-scoped categories, skip if no project on this job
        if ($scope -eq 'project' -and -not $project) {
            $newLines += $line
            continue
        }
        $kbPath = Get-KbPath -Category $cat -Scope $scope -Project $project -KbRoot $KbRoot
        if (-not $kbPath) { $newLines += $line; continue }

        $kbDir = Split-Path -Parent $kbPath
        if (-not (Test-Path $kbDir)) { New-Item -ItemType Directory -Force -Path $kbDir | Out-Null }
        if (-not (Test-Path $kbPath)) {
            Set-Content -Path $kbPath -Value "# $cat`n" -Encoding utf8NoBOM
        }
        $kbLine = "$($m.Groups['ts'].Value) | [$($mani.id)] | $text"
        Add-Content -Path $kbPath -Value $kbLine -Encoding utf8NoBOM
        $newLines += "$line  ✓ consolidated $consolidatedDate"
        $changed = $true
    }
    if ($changed) {
        Set-Content -Path $lessonsPath -Value ($newLines -join "`n") -Encoding utf8NoBOM
    }
}

Write-Host "Consolidation complete." -ForegroundColor Green
