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
