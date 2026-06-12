#!/usr/bin/env pwsh
# Tests for scripts/fleet-doctor.ps1 using the sample fixture.
$ErrorActionPreference = 'Stop'

$doctor  = Join-Path $PSScriptRoot 'fleet-doctor.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# The fixture has: stub-cli (pwsh = on PATH = ok), stub-with-model (pwsh ok),
# stub-with-env (pwsh ok), stub-disabled (skip), stub-http (http to
# localhost:9999 = unreachable = err).
$out = & pwsh -NoProfile -File $doctor -Path $fixture 2>&1 | Out-String
$exit = $LASTEXITCODE

Assert "reports stub-cli" ($out -match 'stub-cli')
Assert "stub-disabled marked skip" ($out -match 'stub-disabled\s+skip')
Assert "stub-http marked err (unreachable)" ($out -match 'stub-http\s+err')
Assert "exit code 1 because an enabled provider errored" ($exit -eq 1)

# usage_class surfaced in -Json output
$jsonOut = & pwsh -NoProfile -File $doctor -Path $fixture -Json 2>&1 | Out-String
$parsed  = $jsonOut | ConvertFrom-Json
$tightRow = @($parsed | Where-Object { $_.NAME -eq 'stub-tight' })
Assert "doctor -Json carries class:tight for stub-tight" ($tightRow.Count -eq 1 -and $tightRow[0].class -eq 'tight')

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
