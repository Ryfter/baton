#!/usr/bin/env pwsh
# Hermetic CLI test for fleet-effective-cost.ps1. Seeds a temp runs root with
# fixture effective-cost.json records and drives the CLI as a child process.
# Never touches real ~/.baton or ~/.claude; zero network.
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot 'fleet-effective-cost.ps1'

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function New-Record([string]$dir, [string]$id, [double]$eff, [string]$worker, [bool]$single) {
    $runDir = Join-Path $dir $id
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $rec = [ordered]@{
        run_id = $id; verdict = 'accept'; quality = 1.0; cost = $eff
        cost_basis = 'estimate'; attempts = 1; effective_cost = $eff
        workers = @([ordered]@{ worker = $worker; share = 1.0 }); single_producer = $single
    }
    ($rec | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $runDir 'effective-cost.json') -Encoding utf8NoBOM
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "fec-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $runsRoot = Join-Path $tmp 'runs'
    New-Item -ItemType Directory -Force -Path $runsRoot | Out-Null
    New-Record $runsRoot 'go-1' 0.05 'cheapw' $true
    New-Record $runsRoot 'go-2' 5.00 'dearw'  $true
    New-Record $runsRoot 'go-3' 0.07 'cheapw' $true
    # A malformed record must be skipped, not crash the run.
    $bad = Join-Path $runsRoot 'go-bad'
    New-Item -ItemType Directory -Force -Path $bad | Out-Null
    Set-Content -LiteralPath (Join-Path $bad 'effective-cost.json') -Value '{ not json' -Encoding utf8NoBOM

    # C1: report ranks the cheapest quality-adjusted worker first.
    $out = (& pwsh -NoProfile -File $cli report -RunsRoot $runsRoot 2>$null | Out-String)
    Check 'C1 exit 0 on report' ($LASTEXITCODE -eq 0)
    Check 'C2 heading present' ($out -match '(?m)^## Effective-cost leaderboard')
    Check 'C3 both workers listed' (($out -match 'cheapw') -and ($out -match 'dearw'))
    Check 'C4 cheapest worker ranked above dearest' ($out.IndexOf('cheapw') -lt $out.IndexOf('dearw'))
    Check 'C5 malformed record did not crash the run (3 records folded)' ($out -match 'Across 3 run')

    # C6/C7: --json emits a parseable rows array.
    $jsonOut = (& pwsh -NoProfile -File $cli report -RunsRoot $runsRoot -Json 2>$null | Out-String)
    Check 'C6 --json exit 0' ($LASTEXITCODE -eq 0)
    $parsed = $jsonOut | ConvertFrom-Json
    Check 'C7 json parses to per-worker rows' ((@($parsed).Count -eq 2) -and (@($parsed).worker -contains 'cheapw'))

    # C8: empty runs root -> guidance, still exit 0.
    $emptyRoot = Join-Path $tmp 'empty-runs'
    New-Item -ItemType Directory -Force -Path $emptyRoot | Out-Null
    $emptyOut = (& pwsh -NoProfile -File $cli report -RunsRoot $emptyRoot 2>$null | Out-String)
    Check 'C8 empty root exit 0' ($LASTEXITCODE -eq 0)
    Check 'C9 empty root prints guidance' ($emptyOut -match 'No effective-cost records')

    # C10: unknown subcommand -> exit 2.
    & pwsh -NoProfile -File $cli bogus -RunsRoot $runsRoot 2>$null | Out-Null
    Check 'C10 unknown subcommand exits 2' ($LASTEXITCODE -eq 2)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green; exit 0
}
