#!/usr/bin/env pwsh
# Tests for scripts/six-hats-lib.ps1 (Build-SixHatsTasks) + integration with
# Invoke-FleetEnsembleTasks via stub providers.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'six-hats-lib.ps1')
. (Join-Path $PSScriptRoot 'fleet-ensemble.ps1')

$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$noState = Join-Path $env:TEMP "six-hats-nostate-$(Get-Random).json"
$env:CAO_STATE_PATH = $noState

# --- T1: Build-SixHatsTasks returns 6 tasks with canonical labels ---
$tasks = Build-SixHatsTasks -Question 'Should we adopt X?' -Providers @('stub-cli')
Assert "T1 six tasks" ($tasks.Count -eq 6)
$labels = $tasks | ForEach-Object { $_.label }
$expected = @('white','red','black','yellow','green','blue')
Assert "T1 canonical hat order" (-not (Compare-Object $labels $expected -SyncWindow 0))
Assert "T1 each task has provider" (@($tasks | Where-Object { $_.provider }).Count -eq 6)
Assert "T1 each task prompt mentions question" (@($tasks | Where-Object { $_.prompt -match 'Should we adopt X' }).Count -eq 6)
Assert "T1 white preamble present" ($tasks[0].prompt -match 'WHITE HAT')
Assert "T1 blue preamble present" ($tasks[5].prompt -match 'BLUE HAT')

# --- T2: Rotation with 1 provider (all hats use it) ---
$t2 = Build-SixHatsTasks -Question 'Q2' -Providers @('p1')
Assert "T2 all six hats use p1" ((@($t2 | Where-Object { $_.provider -eq 'p1' }).Count) -eq 6)

# --- T3: Rotation with 2 providers ---
$t3 = Build-SixHatsTasks -Question 'Q3' -Providers @('p1','p2')
Assert "T3 white -> p1" ($t3[0].provider -eq 'p1')
Assert "T3 red   -> p2" ($t3[1].provider -eq 'p2')
Assert "T3 black -> p1" ($t3[2].provider -eq 'p1')
Assert "T3 blue  -> p2" ($t3[5].provider -eq 'p2')

# --- T4: Rotation with 6 providers (each hat unique) ---
$t4 = Build-SixHatsTasks -Question 'Q4' -Providers @('p1','p2','p3','p4','p5','p6')
$uniq = ($t4 | ForEach-Object { $_.provider } | Sort-Object -Unique)
Assert "T4 six unique providers" ($uniq.Count -eq 6)

# --- T5: Empty roster throws ---
$threw = $false
try { Build-SixHatsTasks -Question 'Q5' -Providers @() | Out-Null } catch { $threw = $true }
Assert "T5 empty roster throws" $threw

# --- T6: Integration — six hats run via stub-cli, all 6 files written ---
$out6 = Join-Path $env:TEMP "six-hats-out-$(Get-Random)"
$jrn6 = Join-Path $env:TEMP "six-hats-jrn-$(Get-Random).md"
$tasks6 = Build-SixHatsTasks -Question 'IntegrationQ' -Providers @('stub-cli')
$m6 = Invoke-FleetEnsembleTasks -Tasks $tasks6 -OutputDir $out6 `
        -FleetPath $fixture -JournalPath $jrn6 -TimeoutS 60
Assert "T6 six manifest entries" ($m6.Count -eq 6)
Assert "T6 all six labels in manifest" ((@($m6 | Where-Object { $expected -contains $_.label }).Count) -eq 6)
foreach ($hat in $expected) {
    $f = Join-Path $out6 "$hat.md"
    Assert "T6 $hat.md exists" (Test-Path $f)
}
Assert "T6 white file content shape" ((Get-Content (Join-Path $out6 'white.md') -Raw) -match 'hello-')
# 6 journal lines (one per hat) — provider repeated 6 times since roster=1
$lines6 = @(Get-Content $jrn6 | Where-Object { $_ -match '\| fleet \|' })
Assert "T6 six journal lines" ($lines6.Count -eq 6)
Remove-Item $out6 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn6 -ErrorAction SilentlyContinue

# --- T7: Partial failure — one hat's provider fails, others succeed ---
$out7 = Join-Path $env:TEMP "six-hats-fail-$(Get-Random)"
$jrn7 = Join-Path $env:TEMP "six-hats-failj-$(Get-Random).md"
# Use 2 providers — one good, one failing. Hats 0/2/4 -> stub-cli, 1/3/5 -> stub-fail.
$tasks7 = Build-SixHatsTasks -Question 'PartialQ' -Providers @('stub-cli','stub-fail')
$m7 = Invoke-FleetEnsembleTasks -Tasks $tasks7 -OutputDir $out7 `
        -FleetPath $fixture -JournalPath $jrn7 -TimeoutS 60
$ok = @($m7 | Where-Object { $_.status -eq 'ok' })
$err = @($m7 | Where-Object { $_.status -eq 'error' })
Assert "T7 three OK" ($ok.Count -eq 3)
Assert "T7 three errors" ($err.Count -eq 3)
Assert "T7 red.md has error marker" ((Get-Content (Join-Path $out7 'red.md') -Raw) -match '\[ENSEMBLE ERROR\]')
Assert "T7 white.md has real content" ((Get-Content (Join-Path $out7 'white.md') -Raw) -match 'hello-')
Remove-Item $out7 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn7 -ErrorAction SilentlyContinue

Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
