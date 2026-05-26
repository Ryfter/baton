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

Write-Host "All tests passed." -ForegroundColor Green
