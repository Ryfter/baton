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

# --- fleet doctor --live (end-to-end, real Invoke-Fleet against fixture) ---
# Fixture roster: stub-cli/stub-with-model/stub-with-env (echo prompt -> contains
# PONG -> live_ok), stub-disabled (skip), stub-http (localhost:9999 -> unreachable),
# stub-fail (no {{prompt}} -> dispatch throws -> dispatch-error), stub-slow (sleep 10
# -> timeout at --timeout 3). Mixed roster -> exit 1.
$liveOut = & pwsh -NoProfile -File $doctor -Path $fixture -Live -TimeoutS 3 2>&1 | Out-String
$liveExit = $LASTEXITCODE
Assert "live: stub-cli reports live_ok"        ($liveOut -match 'stub-cli\s+.*live_ok')
Assert "live: stub-disabled reports skip"      ($liveOut -match 'stub-disabled\s+.*skip')
Assert "live: stub-http reports unreachable"   ($liveOut -match 'stub-http\s+.*(live_fail|unreachable)')
Assert "live: exit 1 on a mixed roster"        ($liveExit -eq 1)

# --json shape
$liveJson = & pwsh -NoProfile -File $doctor -Path $fixture -Live -TimeoutS 3 -Json 2>&1 | Out-String
$parsedLive = $liveJson | ConvertFrom-Json
$cliRow = @($parsedLive | Where-Object { $_.name -eq 'stub-cli' })
Assert "live --json: stub-cli row carries live=live_ok" ($cliRow.Count -eq 1 -and $cliRow[0].live -eq 'live_ok')

# All-live_ok roster -> exit 0 (hermetic single-provider temp yaml)
$tmpYaml = New-TemporaryFile
@'
providers:
  - name: only-ok
    kind: cli
    enabled: true
    cost_tier: free
    command_template: 'pwsh -NoProfile -Command "Write-Output PONG-{{prompt}}"'
'@ | Set-Content -LiteralPath $tmpYaml -Encoding utf8NoBOM
$okOut = & pwsh -NoProfile -File $doctor -Path $tmpYaml -Live -TimeoutS 10 2>&1 | Out-String
$okExit = $LASTEXITCODE
Assert "live: all-live_ok roster -> exit 0" ($okExit -eq 0)
Remove-Item $tmpYaml -ErrorAction SilentlyContinue

# Default (non-live) path unchanged: still reports PATH-based skip/err and exit 1
$plainOut = & pwsh -NoProfile -File $doctor -Path $fixture 2>&1 | Out-String
Assert "non-live path still reports stub-disabled skip" ($plainOut -match 'stub-disabled\s+skip')

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
