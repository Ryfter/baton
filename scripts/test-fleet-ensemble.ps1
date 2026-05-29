#!/usr/bin/env pwsh
# Tests for scripts/fleet-ensemble.ps1 (Invoke-FleetEnsemble) using stub providers.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-ensemble.ps1')

$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$noState = Join-Path $env:TEMP "ens-nostate-$(Get-Random).json"
$env:CAO_STATE_PATH = $noState   # no active job → untagged journal lines

# --- Test 1: basic concurrent success (2 providers) ---
$out1 = Join-Path $env:TEMP "ens-out1-$(Get-Random)"
$jrn1 = Join-Path $env:TEMP "ens-jrn1-$(Get-Random).md"
$m1 = Invoke-FleetEnsemble -Providers @('stub-cli','stub-with-model') -Prompt 'Q1' `
        -OutputDir $out1 -FleetPath $fixture -JournalPath $jrn1 -TimeoutS 60
Assert "T1 manifest has 2 entries" ($m1.Count -eq 2)
Assert "T1 stub-cli.md written" (Test-Path (Join-Path $out1 'stub-cli.md'))
Assert "T1 stub-cli content" ((Get-Content (Join-Path $out1 'stub-cli.md') -Raw).Trim() -eq 'hello-Q1')
Assert "T1 stub-with-model content" ((Get-Content (Join-Path $out1 'stub-with-model.md') -Raw).Trim() -eq 'default-model:Q1')
Assert "T1 both status ok" (@($m1 | Where-Object { $_.status -eq 'ok' }).Count -eq 2)
$fleetLines = @(Get-Content $jrn1 | Where-Object { $_ -match '\| fleet \|' })
Assert "T1 exactly 2 journal lines" ($fleetLines.Count -eq 2)
$shapeRe = '^\d{4}-\d{2}-\d{2}T\S+ \| fleet \| \S+ \| \d+s \| exit:-?\d+ \| ".*"'
Assert "T1 journal lines well-formed" (@($fleetLines | Where-Object { $_ -match $shapeRe }).Count -eq 2)
Remove-Item $out1 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn1 -ErrorAction SilentlyContinue

# --- Test 2: partial failure (stub-fail) doesn't sink the ensemble ---
$out2 = Join-Path $env:TEMP "ens-out2-$(Get-Random)"
$jrn2 = Join-Path $env:TEMP "ens-jrn2-$(Get-Random).md"
$m2 = Invoke-FleetEnsemble -Providers @('stub-cli','stub-fail') -Prompt 'Q2' `
        -OutputDir $out2 -FleetPath $fixture -JournalPath $jrn2 -TimeoutS 60
Assert "T2 manifest has 2 entries" ($m2.Count -eq 2)
Assert "T2 stub-cli ok" ((($m2 | Where-Object { $_.provider -eq 'stub-cli' }).status) -eq 'ok')
Assert "T2 stub-fail error" ((($m2 | Where-Object { $_.provider -eq 'stub-fail' }).status) -eq 'error')
Assert "T2 stub-fail file has error marker" ((Get-Content (Join-Path $out2 'stub-fail.md') -Raw) -match '\[ENSEMBLE ERROR\]')
Remove-Item $out2 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn2 -ErrorAction SilentlyContinue

# --- Test 3: timeout (stub-slow sleeps 10s, timeout 2s) ---
$out3 = Join-Path $env:TEMP "ens-out3-$(Get-Random)"
$jrn3 = Join-Path $env:TEMP "ens-jrn3-$(Get-Random).md"
$t0 = Get-Date
$m3 = Invoke-FleetEnsemble -Providers @('stub-slow') -Prompt 'Q3' `
        -OutputDir $out3 -FleetPath $fixture -JournalPath $jrn3 -TimeoutS 2
$elapsed = ((Get-Date) - $t0).TotalSeconds
Assert "T3 status timeout" ((($m3 | Where-Object { $_.provider -eq 'stub-slow' }).status) -eq 'timeout')
Assert "T3 file has timeout marker" ((Get-Content (Join-Path $out3 'stub-slow.md') -Raw) -match '\[ENSEMBLE TIMEOUT\]')
Assert "T3 returned well under the 10s sleep" ($elapsed -lt 8)
Remove-Item $out3 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn3 -ErrorAction SilentlyContinue

Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
