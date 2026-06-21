#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/gate-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: severity rank + per-reviewer parse (pure) ----
    Check 'G1 critical -> 3'  ((Get-FindingSeverityRank 'critical')  -eq 3)
    Check 'G2 important -> 2' ((Get-FindingSeverityRank 'important') -eq 2)
    Check 'G3 minor -> 1'     ((Get-FindingSeverityRank 'minor')     -eq 1)
    Check 'G4 unknown -> 0'   ((Get-FindingSeverityRank 'banana')    -eq 0)
    Check 'G5 case-insensitive' ((Get-FindingSeverityRank 'CRITICAL') -eq 3)

    $bare = Get-ReviewFindings -Output '[{"severity":"important","area":"correctness","summary":"off by one"}]'
    Check 'G6 bare array parses' ($bare.parsed -and @($bare.findings).Count -eq 1 -and $bare.findings[0].severity -eq 'important')
    $empty = Get-ReviewFindings -Output '[]'
    Check 'G7 empty array -> parsed, 0 findings' ($empty.parsed -and @($empty.findings).Count -eq 0)
    $bad = Get-ReviewFindings -Output 'I could not find any structured issues, sorry.'
    Check 'G8 garbage -> not parsed' (-not $bad.parsed -and @($bad.findings).Count -eq 0)
    $prose = Get-ReviewFindings -Output 'Here are my findings: [{"severity":"minor","area":"style","summary":"naming"}] — done.'
    Check 'G9 array-in-prose parses' ($prose.parsed -and @($prose.findings).Count -eq 1 -and $prose.findings[0].area -eq 'style')
    $unk = Get-ReviewFindings -Output '[{"severity":"blocker","area":"x","summary":"y"}]'
    Check 'G10 unknown severity floored to minor, not dropped' ($unk.parsed -and @($unk.findings).Count -eq 1 -and $unk.findings[0].severity -eq 'minor')
    $trim = Get-ReviewFindings -Output '[{"severity":" Important ","area":"  perf ","summary":" slow "}]'
    Check 'G11 fields normalized/trimmed' ($trim.findings[0].severity -eq 'important' -and $trim.findings[0].area -eq 'perf' -and $trim.findings[0].summary -eq 'slow')
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED"; exit 1 }
    Write-Host "`nALL PASS"
}
