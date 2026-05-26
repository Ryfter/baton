#!/usr/bin/env pwsh
# Unit-style tests for job-lib.ps1 functions.
# Each section dot-sources the lib and runs assertions; throws on failure.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'job-lib.ps1')

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

# --- State file R/W ---
Write-Host "=== State file R/W ===" -ForegroundColor Cyan
$tmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-test-$(Get-Random)") -Force
$statePath = Join-Path $tmpDir 'current-job.json'

# Read when file missing → returns $null
$state = Read-CurrentJob -StatePath $statePath
Assert-Null $state.job_id 'missing state file: job_id is null'
Assert-Null $state.phase 'missing state file: phase is null'

# Write then read
Write-CurrentJob -StatePath $statePath -JobId 'j-test-foo' -Phase 'research'
$state = Read-CurrentJob -StatePath $statePath
Assert-Equal 'j-test-foo' $state.job_id 'after write: job_id matches'
Assert-Equal 'research'   $state.phase  'after write: phase matches'

# Clear
Clear-CurrentJob -StatePath $statePath
$state = Read-CurrentJob -StatePath $statePath
Assert-Null $state.job_id 'after clear: job_id is null'

# Corrupted file → read returns null, no throw
Set-Content $statePath '{ broken json'
$state = Read-CurrentJob -StatePath $statePath
Assert-Null $state.job_id 'corrupted file: job_id is null'

Remove-Item $tmpDir -Recurse -Force

# --- Slugify ---
Write-Host "=== Slugify ===" -ForegroundColor Cyan
Assert-Equal 'feature-flag-system-orchestrator' (ConvertTo-JobSlug "build a feature flag system for the orchestrator") 'normal brief'
Assert-Equal 'rewrite-auth-middleware' (ConvertTo-JobSlug "Rewrite the auth middleware") 'simple brief'
Assert-Equal 'fix-bug' (ConvertTo-JobSlug "fix bug") 'short brief, single token after stops'
Assert-Equal 'fix-bug-in-login-flow' (ConvertTo-JobSlug "fix a bug in the login flow") 'stop-word filtering'

# Length cap (40)
$long = ConvertTo-JobSlug "implement comprehensive multi-tenant role-based access control"
if ($long.Length -gt 40) { throw "FAIL: slug length exceeded 40: $long ($($long.Length) chars)" }

# --- Project detection ---
Write-Host "=== Project detection ===" -ForegroundColor Cyan
$projTmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-proj-$(Get-Random)") -Force
Push-Location $projTmp
try {
    # cwd-folder fallback (no git remote)
    Assert-Equal (Split-Path -Leaf $projTmp) (Resolve-ProjectId) 'cwd folder fallback'

    # Explicit override always wins
    Assert-Equal 'custom-project' (Resolve-ProjectId -Override 'custom-project') 'explicit override'
} finally {
    Pop-Location
    Remove-Item $projTmp -Recurse -Force
}

# --- Phase sequence ---
Write-Host "=== Phase sequence ===" -ForegroundColor Cyan
Assert-Equal 'design'        (Get-NextPhase 'research'      0) 'research → design'
Assert-Equal 'code.sprint-1' (Get-NextPhase 'design'        0) 'design → code.sprint-1'
Assert-Equal 'review'        (Get-NextPhase 'code.sprint-1' 1) 'code.sprint-1 → review'
Assert-Equal 'code.sprint-2' (Get-NextPhase 'review'        1) 'review → code.sprint-2 (sprint_count=1)'
Assert-Equal 'design'        (Get-PrevPhase 'code.sprint-1' 1) 'code.sprint-1 → design (back)'
Assert-Equal 'research'      (Get-PrevPhase 'design'        0) 'design → research (back)'
Assert-Null  (Get-PrevPhase 'research' 0) 'no back from research'

# --- Manifest R/W ---
Write-Host "=== Manifest R/W ===" -ForegroundColor Cyan
$manifestTmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-mani-$(Get-Random)") -Force
$jobDir = Join-Path $manifestTmp 'j-test-123'
New-Item -ItemType Directory -Path $jobDir | Out-Null

$now = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
Write-Manifest -JobDir $jobDir -Manifest @{
    id = 'j-test-123'; title = 'test job'; created_at = $now
    status = 'active'; project = 'test-project'
    current_phase = 'research'; phase_started_at = $now
    sprint_count = 0; last_updated = $now
}
$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'j-test-123'   $mani.id            'manifest id'
Assert-Equal 'research'     $mani.current_phase 'manifest current_phase'
Assert-Equal 0              $mani.sprint_count  'manifest sprint_count'

# --- Phase log append ---
Write-Host "=== Phase log ===" -ForegroundColor Cyan
Append-PhaseLog -JobDir $jobDir -Kind 'created'    -Detail 'research'
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail 'research → design'
$log = Get-Content (Join-Path $jobDir 'phase-log.md') -Raw
if ($log -notmatch 'created\s+\|\s+research')      { throw "FAIL: phase-log missing created line" }
if ($log -notmatch 'transition\s+\|\s+research → design') { throw "FAIL: phase-log missing transition" }

Remove-Item $manifestTmp -Recurse -Force

# --- Lesson categories + scope ---
Write-Host "=== Lesson categories ===" -ForegroundColor Cyan
Assert-Equal 'universal' (Get-LessonDefaultScope 'user-pref') 'user-pref defaults to universal'
Assert-Equal 'universal' (Get-LessonDefaultScope 'routing')   'routing defaults to universal'
Assert-Equal 'project'   (Get-LessonDefaultScope 'mistake')   'mistake defaults to project'
Assert-Equal 'project'   (Get-LessonDefaultScope 'convention') 'convention defaults to project'
Assert-Equal 'project'   (Get-LessonDefaultScope 'knowledge')  'knowledge defaults to project'
if ((Test-LessonCategory 'bogus')) { throw "FAIL: bogus should not validate as a category" }
if (-not (Test-LessonCategory 'mistake')) { throw "FAIL: mistake should validate" }

Write-Host "All tests passed." -ForegroundColor Green
