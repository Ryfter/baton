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
    status = 'active'; project = 'baton'
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

Write-Host "=== /job-phase next ===" -ForegroundColor Cyan

# Already have an active job from /job-start test above.
$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'research' $mani.current_phase 'precondition: phase = research'

# Replicate /job-phase next logic
$newPhase = Get-NextPhase -Current $mani.current_phase -SprintCount $mani.sprint_count
$now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
$mani.current_phase = $newPhase
$mani.phase_started_at = $now
$mani.last_updated = $now
Write-Manifest -JobDir $jobDir -Manifest $mani
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail "research → $newPhase"
Write-CurrentJob -StatePath $statePath -JobId $jobId -Phase $newPhase

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'design' $mani.current_phase 'after next: phase = design'

# next again → code.sprint-1
$newPhase = Get-NextPhase -Current $mani.current_phase -SprintCount $mani.sprint_count
$mani.current_phase = $newPhase
if ($newPhase -match '^code\.sprint-(\d+)$') { $mani.sprint_count = [int]$matches[1] }
Write-Manifest -JobDir $jobDir -Manifest $mani
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail "design → $newPhase"
Write-CurrentJob -StatePath $statePath -JobId $jobId -Phase $newPhase

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'code.sprint-1' $mani.current_phase 'after next: phase = code.sprint-1'
Assert-Equal 1               $mani.sprint_count  'sprint_count = 1'

Write-Host "=== /job-phase back ===" -ForegroundColor Cyan
$prev = Get-PrevPhase -Current $mani.current_phase -SprintCount $mani.sprint_count
$mani.current_phase = $prev
# Don't decrement sprint_count on back — we only count entries, not net state
Write-Manifest -JobDir $jobDir -Manifest $mani
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail "code.sprint-1 → $prev (back)"
Write-CurrentJob -StatePath $statePath -JobId $jobId -Phase $prev

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'design' $mani.current_phase 'after back: phase = design'

Write-Host "=== /job-phase done ===" -ForegroundColor Cyan
$oldPhase = $mani.current_phase     # capture BEFORE mutating, matching the production /job-phase command
$mani.status = 'done'
$mani.current_phase = 'done'
Write-Manifest -JobDir $jobDir -Manifest $mani
Append-PhaseLog -JobDir $jobDir -Kind 'transition' -Detail "$oldPhase → done"
Clear-CurrentJob -StatePath $statePath

$mani = Read-Manifest -JobDir $jobDir
Assert-Equal 'done' $mani.status 'after done: status = done'
Assert-FileMissing $statePath 'after done: state file deleted'

Write-Host "=== /job-resume ===" -ForegroundColor Cyan

# Set up a "previously-active" job by writing manifest then clearing state.
$resumeId = 'j-test-resume-job'
$resumeDir = Join-Path $jobsRoot $resumeId
New-Item -ItemType Directory -Path $resumeDir | Out-Null
$rNow = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
Write-Manifest -JobDir $resumeDir -Manifest @{
    id = $resumeId; title = 'resume test'; created_at = $rNow
    status = 'active'; project = 'test'
    current_phase = 'code.sprint-2'; phase_started_at = $rNow
    sprint_count = 2; last_updated = $rNow
}
Set-Content -Path (Join-Path $resumeDir 'brief.md') -Value "# Brief`n`nresume test" -Encoding utf8NoBOM
Clear-CurrentJob -StatePath $statePath

# Now resume — should restore state file from manifest
$mani = Read-Manifest -JobDir $resumeDir
Write-CurrentJob -StatePath $statePath -JobId $mani.id -Phase $mani.current_phase

$state = Read-CurrentJob -StatePath $statePath
Assert-Equal $resumeId       $state.job_id 'resume: job_id restored'
Assert-Equal 'code.sprint-2' $state.phase  'resume: phase restored from manifest'

# Cleanup
Remove-Item $root -Recurse -Force
Write-Host "All tests passed." -ForegroundColor Green
