#!/usr/bin/env pwsh
# End-to-end dispatch tests using stub providers (no real CLIs / network).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$tmpJournal = Join-Path $env:TEMP "fleet-disp-journal-$(Get-Random).md"
$noState    = Join-Path $env:TEMP "fleet-disp-nostate-$(Get-Random).json"

# --- cli dispatch ---
$env:CAO_STATE_PATH = $noState
try {
    $r = Invoke-Fleet -Name 'stub-cli' -Prompt 'world' -Path $fixture -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "cli dispatch captures stdout" (($r.stdout | Out-String).Trim() -eq 'hello-world')
Assert "cli dispatch exit 0" ($r.exit_code -eq 0)
Assert "cli dispatch measured duration" ($r.duration_s -ge 0)
Assert "cli dispatch wrote journal line" (@(Get-Content $tmpJournal | Where-Object { $_ -match '\| fleet \| stub-cli \|' }).Count -ge 1)

# --- model substitution through dispatch ---
$env:CAO_STATE_PATH = $noState
try {
    $r2 = Invoke-Fleet -Name 'stub-with-model' -Prompt 'p' -Model 'm123' -Path $fixture -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "model passed through dispatch" (($r2.stdout | Out-String).Trim() -eq 'm123:p')

# --- env var applied during call, restored after ---
$before = [Environment]::GetEnvironmentVariable('FLEET_TEST_VAR')
$env:CAO_STATE_PATH = $noState
try {
    $null = Invoke-Fleet -Name 'stub-with-env' -Prompt 'x' -Path $fixture -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$after = [Environment]::GetEnvironmentVariable('FLEET_TEST_VAR')
Assert "env var restored after dispatch" ($before -eq $after)

# --- disabled provider refused ---
$threw = $false
try { Invoke-Fleet -Name 'stub-disabled' -Prompt 'x' -Path $fixture -JournalPath $tmpJournal } catch { $threw = $true }
Assert "disabled provider refused" ($threw)

# --- unknown provider refused ---
$threw2 = $false
try { Invoke-Fleet -Name 'does-not-exist' -Prompt 'x' -Path $fixture -JournalPath $tmpJournal } catch { $threw2 = $true }
Assert "unknown provider refused" ($threw2)

Remove-Item $tmpJournal -ErrorAction SilentlyContinue

# --- http dispatch via stub escape hatch ---
$tmpJournal2 = Join-Path $env:TEMP "fleet-http-journal-$(Get-Random).md"
$noState2    = Join-Path $env:TEMP "fleet-http-nostate-$(Get-Random).json"
$env:CAO_STATE_PATH = $noState2
try {
    $rh = Invoke-Fleet -Name 'stub-http' -Prompt 'ping' -Path $fixture -JournalPath $tmpJournal2
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "http dispatch calls Invoke-StubHttp" ($rh.stdout -eq 'stub-http-response:ping')
Assert "http dispatch exit 0" ($rh.exit_code -eq 0)
Assert "http dispatch journaled" (@(Get-Content $tmpJournal2 | Where-Object { $_ -match '\| fleet \| stub-http \|' }).Count -ge 1)
Remove-Item $tmpJournal2 -ErrorAction SilentlyContinue

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
