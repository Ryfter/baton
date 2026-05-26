#!/usr/bin/env pwsh
# Unit-style tests for job-lib.ps1 functions.
# Each section dot-sources the lib and runs assertions; throws on failure.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'job-lib.ps1')

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

Write-Host "All tests passed." -ForegroundColor Green
