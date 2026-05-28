#!/usr/bin/env pwsh
# Tests for scripts/fleet-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# --- Read-Fleet ---
$fleet = Read-Fleet -Path $fixture
Assert "Read-Fleet returns 5 providers" ($fleet.Count -eq 5)
Assert "first provider name is stub-cli" ($fleet[0].name -eq 'stub-cli')
Assert "stub-cli kind is cli" ($fleet[0].kind -eq 'cli')
Assert "stub-cli enabled is boolean true" ($fleet[0].enabled -eq $true)
Assert "stub-disabled enabled is boolean false" (($fleet | Where-Object { $_.name -eq 'stub-disabled' }).enabled -eq $false)
Assert "stub-with-model has model_default" (($fleet | Where-Object { $_.name -eq 'stub-with-model' }).model_default -eq 'default-model')
Assert "stub-with-env has env hashtable" (($fleet | Where-Object { $_.name -eq 'stub-with-env' }).env.FLEET_TEST_VAR -eq 'box2-value')
Assert "stub-http has base_url" (($fleet | Where-Object { $_.name -eq 'stub-http' }).base_url -eq 'http://localhost:9999')

# --- Get-FleetProvider ---
$p = Get-FleetProvider -Name 'stub-cli' -Path $fixture
Assert "Get-FleetProvider finds stub-cli" ($p.name -eq 'stub-cli')
$missing = Get-FleetProvider -Name 'does-not-exist' -Path $fixture
Assert "Get-FleetProvider returns null for missing" ($null -eq $missing)

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
