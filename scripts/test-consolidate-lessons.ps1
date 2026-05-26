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

# lessons.md with three entries — two scopes, three categories
@"
# Lessons — $jobId

## research
2026-05-26T11:20:00-06:00 | knowledge | "Feature flags split into release vs ops toggles"

## code.sprint-1
2026-05-26T12:55:00-06:00 | mistake | "devstral generated flag write without locking"
2026-05-26T13:05:00-06:00 | user-pref | "Kevin prefers single-file TOML config"
"@ | Set-Content (Join-Path $jobDir 'lessons.md') -Encoding utf8NoBOM

# Run consolidate
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'consolidate-lessons.ps1') `
    -JobsRoot $jobsRoot -KbRoot $kbRoot | Out-Null

# Assertions: routing by category
$mistakes = Get-Content "$kbRoot/projects/testproj/mistakes.md" -Raw
Assert-Match 'devstral generated flag write' $mistakes 'mistake → projects/testproj/mistakes.md'
Assert-Match "\[$jobId\]" $mistakes 'mistake line carries source job tag'

$userPrefs = Get-Content "$kbRoot/universal/user-prefs.md" -Raw
Assert-Match 'single-file TOML' $userPrefs 'user-pref → universal/user-prefs.md'

$topic = Get-Content "$kbRoot/projects/testproj/topics/general.md" -Raw
Assert-Match 'release vs ops toggles' $topic 'knowledge → projects/testproj/topics/general.md'

# Source lessons.md should be marked consolidated
$lessons = Get-Content (Join-Path $jobDir 'lessons.md') -Raw
Assert-Match '✓ consolidated' $lessons 'source entries marked consolidated'

# Idempotency: second run is a no-op (no duplicate entries)
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'consolidate-lessons.ps1') `
    -JobsRoot $jobsRoot -KbRoot $kbRoot | Out-Null

$mistakesAfter = Get-Content "$kbRoot/projects/testproj/mistakes.md" -Raw
$count1 = ([regex]::Matches($mistakes,      'devstral generated flag write')).Count
$count2 = ([regex]::Matches($mistakesAfter, 'devstral generated flag write')).Count
if ($count1 -ne $count2) { throw "FAIL: second run duplicated entries ($count1 → $count2)" }

Remove-Item $root -Recurse -Force
Write-Host "All tests passed." -ForegroundColor Green
