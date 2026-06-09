#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-dispatch.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-disp-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ===== Task 1: heuristic grader =====
    $passRes = @{ stdout = 'some output'; exit_code = 0; duration_s = 1 }
    $emptyRes = @{ stdout = "   `n  "; exit_code = 0; duration_s = 1 }
    $crashRes = @{ stdout = 'partial'; exit_code = 1; duration_s = 1 }

    $g1 = Test-RoutingOutputHeuristic -Capability 'code-gen' -Result $passRes
    Check 'grader passes non-empty/exit0' ($g1.passed -eq $true -and $g1.score -eq 1.0)

    $g2 = Test-RoutingOutputHeuristic -Capability 'code-gen' -Result $emptyRes
    Check 'grader fails empty output'      ($g2.passed -eq $false -and $g2.reason -eq 'empty output')

    $g3 = Test-RoutingOutputHeuristic -Capability 'code-gen' -Result $crashRes
    Check 'grader fails non-zero exit'     ($g3.passed -eq $false -and $g3.reason -match 'exit 1')

    $jsonOk  = @{ stdout = '{"a":1}'; exit_code = 0; duration_s = 1 }
    $jsonBad = @{ stdout = 'not json'; exit_code = 0; duration_s = 1 }
    Check 'struct-extract valid JSON pass' ((Test-RoutingOutputHeuristic -Capability 'struct-extract' -Result $jsonOk).passed -eq $true)
    Check 'struct-extract bad JSON fail'   ((Test-RoutingOutputHeuristic -Capability 'struct-extract' -Result $jsonBad).reason -eq 'not valid JSON')

    $cmOk = @{ stdout = "fix: tighten parser`n`nbody"; exit_code = 0; duration_s = 1 }
    Check 'commit-msg subject pass'        ((Test-RoutingOutputHeuristic -Capability 'commit-msg' -Result $cmOk).passed -eq $true)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
