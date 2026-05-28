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

# --- Resolve-FleetCommand ---
$cliP = Get-FleetProvider -Name 'stub-cli' -Path $fixture
$cmd = Resolve-FleetCommand -Provider $cliP -Prompt 'foo'
Assert "substitutes {{prompt}}" ($cmd -eq 'pwsh -NoProfile -Command "Write-Output hello-foo"')

$modelP = Get-FleetProvider -Name 'stub-with-model' -Path $fixture
$cmd2 = Resolve-FleetCommand -Provider $modelP -Prompt 'bar'
Assert "uses model_default when no model given" ($cmd2 -eq 'pwsh -NoProfile -Command "Write-Output default-model:bar"')
$cmd3 = Resolve-FleetCommand -Provider $modelP -Prompt 'bar' -Model 'override-model'
Assert "explicit model overrides default" ($cmd3 -eq 'pwsh -NoProfile -Command "Write-Output override-model:bar"')

# Missing {{prompt}} in template should throw
$badProvider = @{ name = 'bad'; kind = 'cli'; command_template = 'echo no-placeholder' }
$threw = $false
try { Resolve-FleetCommand -Provider $badProvider -Prompt 'x' } catch { $threw = $true }
Assert "rejects template lacking {{prompt}}" ($threw)

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
