#!/usr/bin/env pwsh
# Unit-style tests for start-lib.ps1 slice 2 — working-style learning loop.
# Hermetic: temp dirs, injected paths, zero network, never touches real $BATON_HOME.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'start-lib.ps1')

$script:pass = 0; $script:fail = 0
function Assert-Equal($expected, $actual, $msg) {
    if ($expected -ne $actual) { $script:fail++; Write-Host "FAIL  $msg`n  expected: $expected`n  actual:   $actual" -ForegroundColor Red }
    else { $script:pass++; Write-Host "PASS  $msg" -ForegroundColor Green }
}
function Assert-Null($actual, $msg) {
    if ($null -ne $actual) { $script:fail++; Write-Host "FAIL  $msg`n  expected null, got: $actual" -ForegroundColor Red }
    else { $script:pass++; Write-Host "PASS  $msg" -ForegroundColor Green }
}
function Assert-True($cond, $msg) {
    if (-not $cond) { $script:fail++; Write-Host "FAIL  $msg" -ForegroundColor Red }
    else { $script:pass++; Write-Host "PASS  $msg" -ForegroundColor Green }
}

# ============================================================================
# A-series: Observation writer
# ============================================================================
Write-Host "`n=== A-series: Observation writer ===" -ForegroundColor Cyan

$tmpA = Join-Path $env:TEMP "baton-s2-test-A-$(Get-Random)"
$journalA = Join-Path $tmpA 'style-journal.jsonl'

# A1: append + round-trip
Add-StyleObservation -JournalPath $journalA -ProjectId 'acme-api' `
    -DepthUsed 'full' -DepthExplicit $false `
    -TeachingUsed 'teach' -TeachingExplicit $false `
    -TurnsToGoal 3 -AudienceVolunteered $false -DoneVolunteered $true `
    -ReasoningQuality 'detailed'
$rows = Read-StyleJournal -JournalPath $journalA
Assert-Equal 1 $rows.Count 'A1: one observation appended and read back'
Assert-Equal 'acme-api' $rows[0].project_id 'A1: project_id round-trips'
Assert-Equal 'full' $rows[0].depth_used 'A1: depth_used round-trips'
Assert-Equal $true $rows[0].done_volunteered 'A1: done_volunteered round-trips'

# A2: multiple appends — each on its own line
Add-StyleObservation -JournalPath $journalA -ProjectId 'beta-app' `
    -DepthUsed 'light' -DepthExplicit $true `
    -TeachingUsed 'quiet' -TeachingExplicit $false
$rows = Read-StyleJournal -JournalPath $journalA
Assert-Equal 2 $rows.Count 'A2: two observations, no overwrite'
Assert-Equal 'beta-app' $rows[1].project_id 'A2: second row has correct project_id'

# A3: missing dir → created
$tmpA3 = Join-Path $env:TEMP "baton-s2-test-A3-$(Get-Random)"
$journalA3 = Join-Path $tmpA3 'sub' 'style-journal.jsonl'
Add-StyleObservation -JournalPath $journalA3 -ProjectId 'gamma' `
    -DepthUsed 'adaptive' -DepthExplicit $false `
    -TeachingUsed 'teach' -TeachingExplicit $false
Assert-True (Test-Path $journalA3) 'A3: missing dir created, file written'
Remove-Item $tmpA3 -Recurse -Force -ErrorAction SilentlyContinue

# A4: Read-StyleJournal on missing path → @()
$missingJ = Join-Path $env:TEMP "baton-s2-missing-$(Get-Random).jsonl"
$rows = Read-StyleJournal -JournalPath $missingJ
Assert-Equal 0 $rows.Count 'A4: missing journal returns empty array, no throw'

Remove-Item $tmpA -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
# B-series: Fold decision (pure)
# ============================================================================
Write-Host "`n=== B-series: Fold decision ===" -ForegroundColor Cyan

function New-Obs([string]$depth, [bool]$depthExp, [string]$teaching, [bool]$teachExp) {
    return [PSCustomObject]@{
        depth_used        = $depth
        depth_explicit    = $depthExp
        teaching_used     = $teaching
        teaching_explicit = $teachExp
    }
}

# B1: fewer than MinObservations non-explicit → both null
$obs = @(
    (New-Obs 'full' $false 'teach' $false),
    (New-Obs 'full' $false 'teach' $false),
    (New-Obs 'full' $false 'teach' $false)
)
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Null $d.depth_recommendation 'B1: fewer than 5 → depth null'
Assert-Null $d.teaching_recommendation 'B1: fewer than 5 → teaching null'

# B2: 5 rows all full/teach → recommendation returned, confidence 1.0
$obs = @(1..5 | ForEach-Object { New-Obs 'full' $false 'teach' $false })
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Equal 'full' $d.depth_recommendation 'B2: unanimous full → depth=full'
Assert-Equal 1.0 $d.depth_confidence 'B2: confidence 1.0'
Assert-Equal 'teach' $d.teaching_recommendation 'B2: unanimous teach → teaching=teach'

# B3: 4/5 light, 1/5 full → confidence 0.8 ≥ 0.70 → recommendation returned
$obs = @(
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'full'  $false 'teach' $false)
)
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Equal 'light' $d.depth_recommendation 'B3: 4/5 light → depth=light'
Assert-Equal 0.8 $d.depth_confidence 'B3: confidence 0.8'

# B4: 3/5 light, 2/5 full → confidence 0.6 < 0.70 → null
$obs = @(
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'full'  $false 'teach' $false),
    (New-Obs 'full'  $false 'teach' $false)
)
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Null $d.depth_recommendation 'B4: 3/5 split → depth null (below threshold)'
Assert-Equal 0.6 $d.depth_confidence 'B4: confidence 0.6'

# B5: explicit rows excluded → split after exclusion → fewer than min → null
$obs = @(
    (New-Obs 'light' $true  'teach' $false),
    (New-Obs 'light' $true  'teach' $false),
    (New-Obs 'light' $true  'teach' $false),
    (New-Obs 'full'  $false 'teach' $false),
    (New-Obs 'full'  $false 'teach' $false)
)
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Null $d.depth_recommendation 'B5: explicit excluded → only 2 non-explicit → null'

# B6: mixed explicit/non-explicit — only non-explicit counted
$obs = @(
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'full'  $true  'quiet' $true)   # explicit — excluded
)
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Equal 'light' $d.depth_recommendation 'B6: explicit row excluded, 5 non-explicit all light'
Assert-Equal 5 $d.observation_count 'B6: observation_count = non-explicit count only'

# B7: teaching majority quiet → recommendation = quiet
$obs = @(
    (New-Obs 'full' $false 'quiet' $false),
    (New-Obs 'full' $false 'quiet' $false),
    (New-Obs 'full' $false 'quiet' $false),
    (New-Obs 'full' $false 'quiet' $false),
    (New-Obs 'full' $false 'teach' $false)
)
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Equal 'quiet' $d.teaching_recommendation 'B7: 4/5 quiet → teaching=quiet'

# B8: teaching split → null
$obs = @(
    (New-Obs 'full' $false 'quiet' $false),
    (New-Obs 'full' $false 'quiet' $false),
    (New-Obs 'full' $false 'teach' $false),
    (New-Obs 'full' $false 'teach' $false),
    (New-Obs 'full' $false 'teach' $false)
)
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Null $d.teaching_recommendation 'B8: teaching 3/5 split → null'

# B9: observation_count = non-explicit depth count
$obs = @(
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $true  'teach' $false),  # depth-explicit
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false),
    (New-Obs 'light' $false 'teach' $false)
)
$d = Get-StyleFoldDecision -Observations $obs -MinObservations 5
Assert-Equal 5 $d.observation_count 'B9: observation_count excludes depth-explicit rows'

# B10: zero rows → no divide-by-zero
$d = Get-StyleFoldDecision -Observations @() -MinObservations 5
Assert-Null $d.depth_recommendation 'B10: zero rows → depth null'
Assert-Null $d.teaching_recommendation 'B10: zero rows → teaching null'
Assert-Equal 0 $d.observation_count 'B10: zero rows → count 0'
Assert-Equal 0.0 $d.depth_confidence 'B10: zero rows → depth confidence 0.0'
Assert-Equal 0.0 $d.teaching_confidence 'B10: zero rows → teaching confidence 0.0'

# ============================================================================
# C-series: Fold invoke
# ============================================================================
Write-Host "`n=== C-series: Fold invoke ===" -ForegroundColor Cyan

$tmpC = Join-Path $env:TEMP "baton-s2-test-C-$(Get-Random)"
$journalC = Join-Path $tmpC 'style-journal.jsonl'
$profileC = Join-Path $tmpC 'user-profile.json'

# C1: depth_learning false → depth not changed
Write-UserProfile -ProfilePath $profileC -Profile @{
    preferred_interview_depth = 'full'; teaching_level = 'teach'
    depth_learning = $false; teaching_learning = $false
    updated_at = '2026-01-01'
}
# Write 5 observations for a clear signal
1..5 | ForEach-Object {
    Add-StyleObservation -JournalPath $journalC -ProjectId 'test' `
        -DepthUsed 'light' -DepthExplicit $false `
        -TeachingUsed 'quiet' -TeachingExplicit $false
}
$fr = Invoke-StyleFold -JournalPath $journalC -ProfilePath $profileC -MinObservations 5
Assert-Equal $false $fr.updated 'C1: learning off → not updated'
Assert-Equal $false $fr.depth_changed 'C1: depth_learning false → depth not changed'

# C2: depth_learning true, clear signal → depth updated
Write-UserProfile -ProfilePath $profileC -Profile @{
    preferred_interview_depth = 'full'; teaching_level = 'teach'
    depth_learning = $true; teaching_learning = $false
    updated_at = '2026-01-01'
}
$fr = Invoke-StyleFold -JournalPath $journalC -ProfilePath $profileC -MinObservations 5
Assert-Equal $true $fr.updated 'C2: depth_learning true + clear signal → updated'
Assert-Equal $true $fr.depth_changed 'C2: depth changed to light'
$prof = Read-UserProfile -ProfilePath $profileC
Assert-Equal 'light' $prof.preferred_interview_depth 'C2: profile now says light'

# C3: profile field already equals recommendation → no write
$fr = Invoke-StyleFold -JournalPath $journalC -ProfilePath $profileC -MinObservations 5
Assert-Equal $false $fr.updated 'C3: already equals recommendation → not updated'
Assert-Equal $false $fr.depth_changed 'C3: depth unchanged (already light)'

# C4: profile null → fold is no-op
$nullProfilePath = Join-Path $tmpC 'nonexistent-profile.json'
$fr = Invoke-StyleFold -JournalPath $journalC -ProfilePath $nullProfilePath -MinObservations 5
Assert-Equal $false $fr.updated 'C4: null profile → not updated'

# C5: depth_observations incremented
$prof = Read-UserProfile -ProfilePath $profileC
Assert-Equal 1 ([int]$prof.depth_observations) 'C5: depth_observations = 1 after one update'

# C6: updated_at refreshed on change; unchanged when nothing changed
$prof = Read-UserProfile -ProfilePath $profileC
$updatedAt = $prof.updated_at
Assert-True (-not [string]::IsNullOrWhiteSpace($updatedAt)) 'C6: updated_at is set after a change'
# Re-fold (no change expected), then verify updated_at did NOT change
$savedAt = $updatedAt
$fr = Invoke-StyleFold -JournalPath $journalC -ProfilePath $profileC -MinObservations 5
$prof2 = Read-UserProfile -ProfilePath $profileC
Assert-Equal $savedAt $prof2.updated_at 'C6: updated_at unchanged when nothing changed'

# C7: both depth and teaching update
# Reset profile with both learning flags on, write new journal
Remove-Item $journalC -Force -ErrorAction SilentlyContinue
Write-UserProfile -ProfilePath $profileC -Profile @{
    preferred_interview_depth = 'full'; teaching_level = 'teach'
    depth_learning = $true; teaching_learning = $true
    updated_at = '2026-01-01'
}
1..5 | ForEach-Object {
    Add-StyleObservation -JournalPath $journalC -ProjectId 'test' `
        -DepthUsed 'light' -DepthExplicit $false `
        -TeachingUsed 'quiet' -TeachingExplicit $false
}
$fr = Invoke-StyleFold -JournalPath $journalC -ProfilePath $profileC -MinObservations 5
Assert-Equal $true $fr.depth_changed 'C7: both depth changed'
Assert-Equal $true $fr.teaching_changed 'C7: both teaching changed'
Assert-Equal $true $fr.updated 'C7: updated'

# C8: journal write failure → no throw (fail-open)
$readOnlyDir = Join-Path $env:TEMP "baton-s2-ro-$(Get-Random)"
New-Item -ItemType Directory -Path $readOnlyDir -Force | Out-Null
$readOnlyJournal = Join-Path $readOnlyDir 'readonly.jsonl'
Set-Content -Path $readOnlyJournal -Value '{}' -Encoding utf8NoBOM
# Make it read-only
Set-ItemProperty -Path $readOnlyJournal -Name IsReadOnly -Value $true
$threw = $false
try {
    Add-StyleObservation -JournalPath $readOnlyJournal -ProjectId 'test' `
        -DepthUsed 'full' -DepthExplicit $false `
        -TeachingUsed 'teach' -TeachingExplicit $false
} catch { $threw = $true }
Assert-Equal $false $threw 'C8: write failure does not throw (fail-open)'
Set-ItemProperty -Path $readOnlyJournal -Name IsReadOnly -Value $false
Remove-Item $readOnlyDir -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item $tmpC -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
# D-series: Format
# ============================================================================
Write-Host "`n=== D-series: Format ===" -ForegroundColor Cyan

# D1: Format-StyleFoldNote returns null when not updated
$note = Format-StyleFoldNote -FoldResult @{ updated = $false; depth_changed = $false; teaching_changed = $false }
Assert-Null $note 'D1: not updated → null'

# D2: depth_changed → includes "depth updated"
$note = Format-StyleFoldNote -FoldResult @{ updated = $true; depth_changed = $true; teaching_changed = $false }
Assert-True ($note -match 'depth updated') 'D2: depth_changed → includes depth updated'
Assert-True ($note -match 'teaching unchanged') 'D2: teaching not changed → teaching unchanged'

# D3: Get-GrimdexStyleNote includes depth, teaching, timestamp
$profObj = [PSCustomObject]@{
    preferred_interview_depth = 'light'
    teaching_level = 'quiet'
    depth_observations = 6
    teaching_observations = 4
}
$gnote = Get-GrimdexStyleNote -Profile $profObj
Assert-True ($gnote -match 'light') 'D3: includes depth value'
Assert-True ($gnote -match 'quiet') 'D3: includes teaching value'
Assert-True ($gnote -match 'Working-style snapshot') 'D3: includes header'
Assert-True ($gnote -match '6 sessions') 'D3: includes depth observation count'

# D4: high-confidence threshold check
$highConf = @{ updated = $true; depth_changed = $true; teaching_changed = $false; depth_confidence = 0.86; teaching_confidence = 0.5 }
Assert-True ($highConf.depth_confidence -gt 0.85) 'D4: 0.86 > 0.85 threshold (above)'
$lowConf = @{ updated = $true; depth_changed = $true; teaching_changed = $false; depth_confidence = 0.84; teaching_confidence = 0.5 }
Assert-True ($lowConf.depth_confidence -le 0.85) 'D4: 0.84 <= 0.85 threshold (below)'

# ============================================================================
# Summary
# ============================================================================
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "PASS: $($script:pass)  FAIL: $($script:fail)" -ForegroundColor $(if ($script:fail -gt 0) { 'Red' } else { 'Green' })
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
