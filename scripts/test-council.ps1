#!/usr/bin/env pwsh
# Tests for scripts/council-lib.ps1 (R1/R2 task builders + R1 survivor read)
# and integration with Invoke-FleetEnsembleTasks via stub providers.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'council-lib.ps1')
. (Join-Path $PSScriptRoot 'fleet-ensemble.ps1')

$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$noState = Join-Path $env:TEMP "council-nostate-$(Get-Random).json"
$env:CAO_STATE_PATH = $noState

# --- T1: Limits sanity ---
$lim = Get-CouncilLimits
Assert "T1 max=5"   ($lim.max -eq 5)
Assert "T1 quorum=2" ($lim.quorum -eq 2)

# --- T2: R1 tasks: one per provider, label = provider, prompt = question ---
$r1 = Build-CouncilR1Tasks -Question 'Q?' -Providers @('a','b','c')
Assert "T2 three R1 tasks" ($r1.Count -eq 3)
Assert "T2 R1 labels match providers" ((($r1 | ForEach-Object { $_.label }) -join ',') -eq 'a,b,c')
Assert "T2 R1 prompt is the question" ((@($r1 | Where-Object { $_.prompt -eq 'Q?' }).Count) -eq 3)

# --- T3: R1 throws on empty roster ---
$threw = $false
try { Build-CouncilR1Tasks -Question 'Q' -Providers @() | Out-Null } catch { $threw = $true }
Assert "T3 empty roster throws" $threw

# --- T4: R1 caps roster at 5 ---
$big = Build-CouncilR1Tasks -Question 'Q' -Providers @('a','b','c','d','e','f','g') 3>$null
Assert "T4 caps at 5"  ($big.Count -eq 5)
Assert "T4 keeps first 5" ((($big | ForEach-Object { $_.label }) -join ',') -eq 'a,b,c,d,e')

# --- T5: R2 task stitching — peer-only content (self excluded), --- separator ---
$workR1 = Join-Path $env:TEMP "council-r1-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $workR1 | Out-Null
Set-Content -Path (Join-Path $workR1 'a.md') -Value 'Answer-from-A' -Encoding utf8NoBOM
Set-Content -Path (Join-Path $workR1 'b.md') -Value 'Answer-from-B' -Encoding utf8NoBOM
Set-Content -Path (Join-Path $workR1 'c.md') -Value 'Answer-from-C' -Encoding utf8NoBOM
$r2 = Build-CouncilR2Tasks -Question 'Q?' -Providers @('a','b','c') -R1Dir $workR1
Assert "T5 three R2 tasks" ($r2.Count -eq 3)
$aPrompt = ($r2 | Where-Object { $_.provider -eq 'a' }).prompt
Assert "T5 a's prompt contains b" ($aPrompt -match 'Answer-from-B')
Assert "T5 a's prompt contains c" ($aPrompt -match 'Answer-from-C')
Assert "T5 a's prompt does NOT contain own A" (-not ($aPrompt -match 'Answer-from-A'))
Assert "T5 a's prompt has --- separator" ($aPrompt -match ' --- ')

# --- T6: R2 handles a missing/failed R1 with a placeholder note ---
Set-Content -Path (Join-Path $workR1 'b.md') -Value '[ENSEMBLE ERROR] exit:1' -Encoding utf8NoBOM
$r2b = Build-CouncilR2Tasks -Question 'Q?' -Providers @('a','b','c') -R1Dir $workR1
$aPrompt2 = ($r2b | Where-Object { $_.provider -eq 'a' }).prompt
Assert "T6 a's prompt notes b failure" ($aPrompt2 -match 'b: \(no usable R1 answer')
Assert "T6 a's prompt still has c"     ($aPrompt2 -match 'Answer-from-C')
# A failed-R1 member (b) still appears in R2 — second-chance design
Assert "T6 b is still in R2 task list" ((@($r2b | Where-Object { $_.provider -eq 'b' }).Count) -eq 1)
Remove-Item $workR1 -Recurse -Force -ErrorAction SilentlyContinue

# --- T7: Get-CouncilR1Survivors filters status=ok ---
$fakeManifest = @(
    [pscustomobject]@{ provider='a'; status='ok' },
    [pscustomobject]@{ provider='b'; status='error' },
    [pscustomobject]@{ provider='c'; status='ok' }
)
$surv = Get-CouncilR1Survivors -R1Manifest $fakeManifest
Assert "T7 two survivors" ($surv.Count -eq 2)
Assert "T7 a + c survive" (($surv -join ',') -eq 'a,c')

# --- T8: Integration — R1+R2 run end-to-end with stub providers ---
$out = Join-Path $env:TEMP "council-out-$(Get-Random)"
$jrn = Join-Path $env:TEMP "council-jrn-$(Get-Random).md"
$r1Dir = Join-Path $out 'round1'
$r2Dir = Join-Path $out 'round2'
$roster = @('stub-cli','stub-with-model')
$r1Tasks = Build-CouncilR1Tasks -Question 'Q' -Providers $roster
$m1 = Invoke-FleetEnsembleTasks -Tasks $r1Tasks -OutputDir $r1Dir `
        -FleetPath $fixture -JournalPath $jrn -TimeoutS 60
Assert "T8 R1 manifest size 2" ($m1.Count -eq 2)
Assert "T8 R1 both ok" ((@($m1 | Where-Object { $_.status -eq 'ok' }).Count) -eq 2)
$surv8 = Get-CouncilR1Survivors -R1Manifest $m1
Assert "T8 quorum met" ($surv8.Count -ge $lim.quorum)
$r2Tasks = Build-CouncilR2Tasks -Question 'Q' -Providers $roster -R1Dir $r1Dir
$m2 = Invoke-FleetEnsembleTasks -Tasks $r2Tasks -OutputDir $r2Dir `
        -FleetPath $fixture -JournalPath $jrn -TimeoutS 60
Assert "T8 R2 manifest size 2" ($m2.Count -eq 2)
Assert "T8 R1 files present" ((Test-Path (Join-Path $r1Dir 'stub-cli.md')) -and (Test-Path (Join-Path $r1Dir 'stub-with-model.md')))
Assert "T8 R2 files present" ((Test-Path (Join-Path $r2Dir 'stub-cli.md')) -and (Test-Path (Join-Path $r2Dir 'stub-with-model.md')))
$jrnLines = @(Get-Content $jrn | Where-Object { $_ -match '\| fleet \|' })
Assert "T8 four journal lines (2 R1 + 2 R2)" ($jrnLines.Count -eq 4)
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn -ErrorAction SilentlyContinue

# --- T9: Partial R1 failure — 1 of 2 stub-fail, quorum below 2 ---
$out9 = Join-Path $env:TEMP "council-out9-$(Get-Random)"
$jrn9 = Join-Path $env:TEMP "council-jrn9-$(Get-Random).md"
$roster9 = @('stub-cli','stub-fail')
$r1t9 = Build-CouncilR1Tasks -Question 'Q' -Providers $roster9
$m9 = Invoke-FleetEnsembleTasks -Tasks $r1t9 -OutputDir (Join-Path $out9 'round1') `
        -FleetPath $fixture -JournalPath $jrn9 -TimeoutS 60
$surv9 = Get-CouncilR1Survivors -R1Manifest $m9
Assert "T9 only 1 survivor" ($surv9.Count -eq 1)
Assert "T9 below quorum"    ($surv9.Count -lt $lim.quorum)
Remove-Item $out9 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn9 -ErrorAction SilentlyContinue

Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
