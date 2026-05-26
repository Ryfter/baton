#!/usr/bin/env pwsh
# End-to-end job lifecycle tests. Each test sets up an isolated $JOBS_ROOT
# under TEMP, runs slash-command logic (or its PowerShell equivalent), and
# asserts the on-disk state.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'job-lib.ps1')

function Assert-FileExists($path, $msg) {
    if (-not (Test-Path $path)) { throw "FAIL: $msg ($path missing)" }
}

function Assert-FileMissing($path, $msg) {
    if (Test-Path $path) { throw "FAIL: $msg ($path should not exist)" }
}

function Assert-Equal($expected, $actual, $msg) {
    if ($expected -ne $actual) { throw "FAIL: $msg`n  expected: $expected`n  actual:   $actual" }
}

# Isolate everything under a temp dir.
$root = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-e2e-$(Get-Random)") -Force
$jobsRoot  = Join-Path $root 'jobs'
$statePath = Join-Path $root 'current-job.json'
New-Item -ItemType Directory -Path $jobsRoot | Out-Null

Write-Host "=== /job-start ===" -ForegroundColor Cyan

# The slash command's PowerShell logic is replicated here for test isolation.
# When the actual /job-start runs, it sets paths to ~/.claude/...
$brief = 'build a feature flag system for the orchestrator'
$today = Get-Date -Format 'yyyy-MM-dd'
$slug = ConvertTo-JobSlug $brief
$jobId = "j-$today-$slug"
$jobDir = Join-Path $jobsRoot $jobId
$now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'

New-Item -ItemType Directory -Path $jobDir | Out-Null
Set-Content -Path (Join-Path $jobDir 'brief.md') -Value "# Brief`n`n$brief" -Encoding utf8NoBOM
Write-Manifest -JobDir $jobDir -Manifest @{
    id = $jobId; title = $brief; created_at = $now
    status = 'active'; project = 'coding-agent-orchestrator'
    current_phase = 'research'; phase_started_at = $now
    sprint_count = 0; last_updated = $now
}
Append-PhaseLog -JobDir $jobDir -Kind 'created' -Detail 'research'
Write-CurrentJob -StatePath $statePath -JobId $jobId -Phase 'research'

# Assertions
Assert-FileExists (Join-Path $jobDir 'manifest.yaml')   'manifest.yaml created'
Assert-FileExists (Join-Path $jobDir 'brief.md')        'brief.md created'
Assert-FileExists (Join-Path $jobDir 'phase-log.md')    'phase-log.md created'
Assert-FileExists $statePath                            'state file written'

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal $jobId      $mani.id            'manifest id matches'
Assert-Equal 'research'  $mani.current_phase 'manifest current_phase = research'
Assert-Equal 'active'    $mani.status        'manifest status = active'

$state = Read-CurrentJob -StatePath $statePath
Assert-Equal $jobId     $state.job_id 'state file job_id'
Assert-Equal 'research' $state.phase  'state file phase'

# Cleanup
Remove-Item $root -Recurse -Force
Write-Host "All tests passed." -ForegroundColor Green
