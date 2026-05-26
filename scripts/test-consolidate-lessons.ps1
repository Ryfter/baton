#!/usr/bin/env pwsh
# Tests for consolidate-lessons.ps1: routing by category + scope, idempotency, source tagging.

$ErrorActionPreference = 'Stop'

function Assert-Match($pattern, $actual, $msg) {
    if ($actual -notmatch $pattern) { throw "FAIL: $msg`n  pattern: $pattern`n  actual:`n$actual" }
}
function Assert-NotMatch($pattern, $actual, $msg) {
    if ($actual -match $pattern) { throw "FAIL: $msg`n  pattern: $pattern`n  actual:`n$actual" }
}

$root      = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-consol-$(Get-Random)") -Force
$jobsRoot  = Join-Path $root 'jobs'
$kbRoot    = Join-Path $root 'knowledge'
New-Item -ItemType Directory -Force -Path $jobsRoot, "$kbRoot/universal", "$kbRoot/projects" | Out-Null

# Set up one job with mixed-category lessons
$jobId  = 'j-2026-05-26-test'
$jobDir = Join-Path $jobsRoot $jobId
New-Item -ItemType Directory -Path $jobDir | Out-Null

# Minimal manifest
Set-Content (Join-Path $jobDir 'manifest.yaml') -Value @"
id: $jobId
project: testproj
status: active
current_phase: review
"@ -Encoding utf8NoBOM

# lessons.md with entries in both old format (no scope) and new format (with scope).
# The `mistake` entry has an explicit universal override to test scope persistence.
@"
# Lessons — $jobId

## research
2026-05-26T11:20:00-06:00 | knowledge | project | "Feature flags split into release vs ops toggles"

## code.sprint-1
2026-05-26T12:55:00-06:00 | mistake | universal | "devstral generated flag write without locking"
2026-05-26T13:05:00-06:00 | user-pref | "Kevin prefers single-file TOML config"
"@ | Set-Content (Join-Path $jobDir 'lessons.md') -Encoding utf8NoBOM

# Run consolidate
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'consolidate-lessons.ps1') `
    -JobsRoot $jobsRoot -KbRoot $kbRoot | Out-Null

# Assertions: routing by category

# mistake with explicit 'universal' scope override → universal/mistakes.md (NOT projects/testproj/mistakes.md)
$universalMistakes = Get-Content "$kbRoot/universal/mistakes.md" -Raw
Assert-Match 'devstral generated flag write' $universalMistakes 'mistake (universal override) → universal/mistakes.md'
Assert-Match "\[$jobId\]" $universalMistakes 'universal mistake line carries source job tag'
Assert-NotMatch 'devstral generated flag write' (
    (Test-Path "$kbRoot/projects/testproj/mistakes.md") ?
    (Get-Content "$kbRoot/projects/testproj/mistakes.md" -Raw) : ''
) 'mistake with universal scope must NOT appear in projects/testproj/mistakes.md'

# user-pref has no scope field (old format) → defaults to universal
$userPrefs = Get-Content "$kbRoot/universal/user-prefs.md" -Raw
Assert-Match 'single-file TOML' $userPrefs 'user-pref (old format) → universal/user-prefs.md'

# knowledge with explicit 'project' scope → projects/testproj/topics/general.md
$topic = Get-Content "$kbRoot/projects/testproj/topics/general.md" -Raw
Assert-Match 'release vs ops toggles' $topic 'knowledge (project scope) → projects/testproj/topics/general.md'

# Source lessons.md should be marked consolidated
$lessons = Get-Content (Join-Path $jobDir 'lessons.md') -Raw
Assert-Match '✓ consolidated' $lessons 'source entries marked consolidated'

# Idempotency: second run is a no-op (no duplicate entries)
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'consolidate-lessons.ps1') `
    -JobsRoot $jobsRoot -KbRoot $kbRoot | Out-Null

$universalMistakesAfter = Get-Content "$kbRoot/universal/mistakes.md" -Raw
$count1 = ([regex]::Matches($universalMistakes,      'devstral generated flag write')).Count
$count2 = ([regex]::Matches($universalMistakesAfter, 'devstral generated flag write')).Count
if ($count1 -ne $count2) { throw "FAIL: second run duplicated entries ($count1 → $count2)" }

Remove-Item $root -Recurse -Force
Write-Host "All tests passed." -ForegroundColor Green
