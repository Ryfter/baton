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

# --- Test 4: Invoke-FleetEnsembleTasks — heterogeneous tasks (different prompts) ---
$out4 = Join-Path $env:TEMP "ens-out4-$(Get-Random)"
$jrn4 = Join-Path $env:TEMP "ens-jrn4-$(Get-Random).md"
$tasks4 = @(
    @{ label = 'alpha'; provider = 'stub-cli'; prompt = 'Pa' },
    @{ label = 'beta';  provider = 'stub-cli'; prompt = 'Pb' }
)
$m4 = Invoke-FleetEnsembleTasks -Tasks $tasks4 -OutputDir $out4 `
        -FleetPath $fixture -JournalPath $jrn4 -TimeoutS 60
Assert "T4 manifest has 2 entries" ($m4.Count -eq 2)
Assert "T4 alpha label present" ((@($m4 | Where-Object { $_.label -eq 'alpha' }).Count) -eq 1)
Assert "T4 beta  label present" ((@($m4 | Where-Object { $_.label -eq 'beta'  }).Count) -eq 1)
Assert "T4 alpha file is hello-Pa" ((Get-Content (Join-Path $out4 'alpha.md') -Raw).Trim() -eq 'hello-Pa')
Assert "T4 beta  file is hello-Pb" ((Get-Content (Join-Path $out4 'beta.md')  -Raw).Trim() -eq 'hello-Pb')
$lines4 = @(Get-Content $jrn4 | Where-Object { $_ -match '\| fleet \|' })
Assert "T4 two journal lines" ($lines4.Count -eq 2)
# Each journal line should mention the specific per-task prompt, not a shared one
Assert "T4 journal mentions Pa" (($lines4 -join "`n") -match 'Pa')
Assert "T4 journal mentions Pb" (($lines4 -join "`n") -match 'Pb')
Remove-Item $out4 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn4 -ErrorAction SilentlyContinue

# --- Test 5: Invoke-FleetEnsembleTasks — same provider, multiple labels, partial fail ---
$out5 = Join-Path $env:TEMP "ens-out5-$(Get-Random)"
$jrn5 = Join-Path $env:TEMP "ens-jrn5-$(Get-Random).md"
$tasks5 = @(
    @{ label = 'good'; provider = 'stub-cli';  prompt = 'X1' },
    @{ label = 'bad';  provider = 'stub-fail'; prompt = 'X2' },
    @{ label = 'also'; provider = 'stub-cli';  prompt = 'X3' }
)
$m5 = Invoke-FleetEnsembleTasks -Tasks $tasks5 -OutputDir $out5 `
        -FleetPath $fixture -JournalPath $jrn5 -TimeoutS 60
Assert "T5 three entries"     ($m5.Count -eq 3)
Assert "T5 good is ok"        ((($m5 | Where-Object { $_.label -eq 'good' }).status) -eq 'ok')
Assert "T5 bad  is error"     ((($m5 | Where-Object { $_.label -eq 'bad'  }).status) -eq 'error')
Assert "T5 also is ok"        ((($m5 | Where-Object { $_.label -eq 'also' }).status) -eq 'ok')
Assert "T5 bad file has marker" ((Get-Content (Join-Path $out5 'bad.md') -Raw) -match '\[ENSEMBLE ERROR\]')
Remove-Item $out5 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn5 -ErrorAction SilentlyContinue

# --- Test 6: Invoke-FleetEnsembleTasks — empty/invalid task throws ---
$threw = $false
try {
    Invoke-FleetEnsembleTasks -Tasks @(@{ label='x'; prompt='p' }) -OutputDir (Join-Path $env:TEMP "ens-bad-$(Get-Random)") `
        -FleetPath $fixture -JournalPath (Join-Path $env:TEMP "ens-bad-jrn-$(Get-Random).md")
} catch { $threw = $true }
Assert "T6 missing provider throws" $threw

Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
