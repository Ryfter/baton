#!/usr/bin/env pwsh
# Unit-style tests for start-lib.ps1 functions.
# Each section dot-sources the lib and runs assertions; throws on failure.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'start-lib.ps1')

function Assert-Equal($expected, $actual, $msg) {
    if ($expected -ne $actual) {
        throw "FAIL: $msg`n  expected: $expected`n  actual:   $actual"
    }
}

function Assert-Null($actual, $msg) {
    if ($null -ne $actual) {
        throw "FAIL: $msg`n  expected null, got: $actual"
    }
}

function Assert-True($cond, $msg) {
    if (-not $cond) { throw "FAIL: $msg" }
}

# --- Resolve-StartMode ---
Write-Host "=== Resolve-StartMode ===" -ForegroundColor Cyan
Assert-Equal 'new'    (Resolve-StartMode -ProjectRecord $null) 'no record -> new'
Assert-Equal 'resume' (Resolve-StartMode -ProjectRecord @{ id = 'acme-api' }) 'record present -> resume'

# --- Resolve-InterviewDepth ---
Write-Host "=== Resolve-InterviewDepth ===" -ForegroundColor Cyan
Assert-Equal 'full' (Resolve-InterviewDepth -Profile $null -Explicit $null) 'no profile, no explicit -> full (new/unknown user)'
Assert-Equal 'adaptive' (Resolve-InterviewDepth -Profile @{ preferred_interview_depth = $null } -Explicit $null) 'profile present but depth unset -> adaptive'
Assert-Equal 'light' (Resolve-InterviewDepth -Profile @{ preferred_interview_depth = 'light' } -Explicit $null) 'profile says light -> light'
Assert-Equal 'full' (Resolve-InterviewDepth -Profile @{ preferred_interview_depth = 'light' } -Explicit 'full') 'explicit overrides profile'

# --- Resolve-TeachingLevel ---
Write-Host "=== Resolve-TeachingLevel ===" -ForegroundColor Cyan
Assert-Equal 'teach' (Resolve-TeachingLevel -Profile $null -Explicit $null) 'no profile, no explicit -> teach (default)'
Assert-Equal 'teach' (Resolve-TeachingLevel -Profile @{ teaching_level = $null } -Explicit $null) 'profile present but level unset -> teach'
Assert-Equal 'quiet' (Resolve-TeachingLevel -Profile @{ teaching_level = 'quiet' } -Explicit $null) 'profile says quiet -> quiet'
Assert-Equal 'quiet' (Resolve-TeachingLevel -Profile @{ teaching_level = 'teach' } -Explicit 'quiet') 'explicit overrides profile'

# --- Get-NextCommandRecommendation ---
Write-Host "=== Get-NextCommandRecommendation ===" -ForegroundColor Cyan
$rec = Get-NextCommandRecommendation -RunStatus 'completed'
Assert-True ($rec.command -match '/baton:(gate|effective-cost)') 'completed -> recommends gate or effective-cost'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'completed -> has a why'

$rec = Get-NextCommandRecommendation -RunStatus 'interrupted-budget'
Assert-True ($rec.command -match '--budget') 'interrupted-budget -> recommends raising --budget'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'interrupted-budget -> has a why'

$rec = Get-NextCommandRecommendation -RunStatus 'interrupted-destructive'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.command)) 'interrupted-destructive -> has a command'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'interrupted-destructive -> has a why'

$rec = Get-NextCommandRecommendation -RunStatus 'rejected'
Assert-True ($rec.command -match '/baton:gate') 'rejected -> recommends /baton:gate'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'rejected -> has a why'

foreach ($failStatus in @('failed', 'plan-failed', 'plan-invalid')) {
    $rec = Get-NextCommandRecommendation -RunStatus $failStatus
    Assert-True (-not [string]::IsNullOrWhiteSpace($rec.command)) "$failStatus -> has a command"
    Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) "$failStatus -> has a why"
}

$rec = Get-NextCommandRecommendation -RunStatus 'some-unknown-status'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.command)) 'unknown status -> has a command (fallback)'
Assert-True (-not [string]::IsNullOrWhiteSpace($rec.why)) 'unknown status -> has a why (fallback)'

# --- Project record R/W ---
Write-Host "=== Project record R/W ===" -ForegroundColor Cyan
$projRoot = Join-Path $env:TEMP "cao-start-proj-$(Get-Random)"

# Read when missing -> $null, no throw
$rec = Read-ProjectRecord -ProjectId 'acme-api' -ProjectsRoot $projRoot
Assert-Null $rec 'missing project record: read returns null'

# Write then read
$now = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
Write-ProjectRecord -ProjectsRoot $projRoot -Record @{
    id = 'acme-api'; name = 'Acme API'; folder = 'D:/Dev/acme-api'
    charter_path = 'D:/Dev/acme-api/CHARTER.md'
    created_at = $now; last_updated = $now; last_run = $null
}
$rec = Read-ProjectRecord -ProjectId 'acme-api' -ProjectsRoot $projRoot
Assert-Equal 'acme-api'  $rec.id     'project record: id round-trips'
Assert-Equal 'Acme API'  $rec.name   'project record: name round-trips'
Assert-Equal 'D:/Dev/acme-api' $rec.folder 'project record: folder round-trips'

# Corrupted file -> read returns null, no throw
$corruptDir = Join-Path $projRoot 'broken-proj'
New-Item -ItemType Directory -Path $corruptDir -Force | Out-Null
Set-Content -Path (Join-Path $corruptDir 'project.json') -Value '{ not json' -Encoding utf8NoBOM
$rec = Read-ProjectRecord -ProjectId 'broken-proj' -ProjectsRoot $projRoot
Assert-Null $rec 'corrupted project record: read returns null'

Remove-Item $projRoot -Recurse -Force

# --- User profile R/W ---
Write-Host "=== User profile R/W ===" -ForegroundColor Cyan
$profTmp = Join-Path $env:TEMP "cao-start-profile-$(Get-Random)"
$profilePath = Join-Path $profTmp 'user-profile.json'

# Read when missing -> $null, no throw
$prof = Read-UserProfile -ProfilePath $profilePath
Assert-Null $prof 'missing user profile: read returns null'

# Write then read
Write-UserProfile -ProfilePath $profilePath -Profile @{
    preferred_interview_depth = 'light'; teaching_level = 'teach'; updated_at = $now
}
$prof = Read-UserProfile -ProfilePath $profilePath
Assert-Equal 'light' $prof.preferred_interview_depth 'user profile: depth round-trips'
Assert-Equal 'teach' $prof.teaching_level             'user profile: teaching_level round-trips'

# Corrupted file -> read returns null, no throw
$corruptProfilePath = Join-Path $profTmp 'corrupt-profile.json'
Set-Content -Path $corruptProfilePath -Value '{ not json' -Encoding utf8NoBOM
$prof = Read-UserProfile -ProfilePath $corruptProfilePath
Assert-Null $prof 'corrupted user profile: read returns null'

Remove-Item $profTmp -Recurse -Force

# --- New-CharterContent ---
Write-Host "=== New-CharterContent ===" -ForegroundColor Cyan
$charter = New-CharterContent -Name 'Acme API' -Goal 'A backend for the Acme mobile app' `
    -Audience 'Acme mobile team' -Done 'Endpoints match the mobile app spec and pass its test suite' `
    -Reasoning 'Existing backend is unmaintained; a clean rebuild is faster than patching it.'
Assert-True ($charter -match 'Acme API')                                   'charter: name present'
Assert-True ($charter -match 'A backend for the Acme mobile app')          'charter: goal present'
Assert-True ($charter -match 'Acme mobile team')                          'charter: audience present'
Assert-True ($charter -match 'Endpoints match the mobile app spec')       'charter: done present'
Assert-True ($charter -match 'clean rebuild is faster')                   'charter: reasoning present'

$minimal = New-CharterContent -Name 'Solo Tool' -Goal 'A CLI to rename files' -Audience $null -Done $null -Reasoning $null
Assert-True ($minimal -match '\(to be filled in\)') 'charter: empty optional sections render placeholder line'
Assert-True ($minimal -notmatch "`n`n`n")            'charter: no triple-blank-line from empty sections'

# --- Format-ResumeStatus ---
Write-Host "=== Format-ResumeStatus ===" -ForegroundColor Cyan
$noRun = Format-ResumeStatus -ProjectRecord @{ name = 'Acme API'; folder = 'D:/Dev/acme-api'; last_run = $null }
Assert-True ($noRun -match 'Acme API')          'resume status: name present, no prior run'
Assert-True ($noRun -match 'D:/Dev/acme-api')   'resume status: folder present, no prior run'
Assert-True ($noRun -match "hasn't run|has not run|no runs yet") 'resume status: says no prior run'

$withRun = Format-ResumeStatus -ProjectRecord @{
    name = 'Acme API'; folder = 'D:/Dev/acme-api'
    last_run = @{ run_id = 'run-2026-07-01-abc'; status = 'interrupted-budget'; at = '2026-07-01T09:20:00-06:00' }
}
Assert-True ($withRun -match 'Acme API')            'resume status: name present, with prior run'
Assert-True ($withRun -match 'interrupted-budget|budget') 'resume status: reflects last run status'
