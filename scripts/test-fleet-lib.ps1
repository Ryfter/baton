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

# --- Write-FleetJournalLine ---
$tmpJournal = Join-Path $env:TEMP "fleet-journal-$(Get-Random).md"
$tmpState   = Join-Path $env:TEMP "fleet-state-$(Get-Random).json"

# No active job -> line has no job/phase tags
Remove-Item $tmpState -ErrorAction SilentlyContinue
$env:CAO_STATE_PATH = $tmpState
try {
    Write-FleetJournalLine -Provider 'stub-cli' -DurationS 2 -ExitCode 0 -Prompt 'hello world' -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$line = @(Get-Content $tmpJournal | Where-Object { $_ -match '\| fleet \|' })[-1]
Assert "fleet line written" ($line -match '\| fleet \| stub-cli \|')
Assert "fleet line has duration" ($line -match '\| 2s \|')
Assert "fleet line has exit" ($line -match 'exit:0')
Assert "fleet line has prompt summary" ($line -match '"hello world"')
Assert "no-job line has no job tag" ($line -notmatch 'job:')

# With active job -> tags appended. Use job-lib's Write-CurrentJob only to CREATE
# the state file; Write-FleetJournalLine reads it directly via env var.
. (Join-Path $PSScriptRoot 'job-lib.ps1')
Write-CurrentJob -StatePath $tmpState -JobId 'j-fleet-test' -Phase 'research'
$env:CAO_STATE_PATH = $tmpState
try {
    Write-FleetJournalLine -Provider 'stub-cli' -DurationS 1 -ExitCode 0 -Prompt 'tagged' -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$line2 = @(Get-Content $tmpJournal | Where-Object { $_ -match 'tagged' })[-1]
Assert "active-job line has job tag" ($line2 -match 'job:j-fleet-test')
Assert "active-job line has phase tag" ($line2 -match 'phase:research')

# Pipe in prompt sanitized to ¦
$env:CAO_STATE_PATH = (Join-Path $env:TEMP "nope-$(Get-Random).json")
try {
    Write-FleetJournalLine -Provider 'stub-cli' -DurationS 0 -ExitCode 0 -Prompt 'a | b' -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$line3 = @(Get-Content $tmpJournal)[-1]
Assert "pipe in prompt sanitized" ($line3 -match 'a ¦ b')

Remove-Item $tmpJournal, $tmpState -ErrorAction SilentlyContinue

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
