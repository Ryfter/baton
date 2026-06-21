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

    # ---- Task 2: reconcile + verdict (pure) ----
    $r1 = @{ reviewer='r1'; parsed=$true; findings=@(
        @{severity='important';area='correctness';summary='off by one'},
        @{severity='minor';area='style';summary='naming'}) }
    $r2 = @{ reviewer='r2'; parsed=$true; findings=@(
        @{severity='critical';area='correctness';summary='off by one'}) }
    $m = Merge-ReviewFindings -Reviews @($r1,$r2)
    Check 'G12 same finding merges to one' (@($m.merged).Count -eq 2)
    $corr = @($m.merged | Where-Object { $_.area -eq 'correctness' })[0]
    Check 'G13 merge keeps higher severity' ($corr.severity -eq 'critical')
    Check 'G14 merged finding agreed + both raisers' ($corr.agreed -and $corr.raised_by.Count -eq 2)
    $styl = @($m.merged | Where-Object { $_.area -eq 'style' })[0]
    Check 'G15 solo finding not agreed' (-not $styl.agreed -and $styl.raised_by.Count -eq 1)

    $rbad = @{ reviewer='r3'; parsed=$false; findings=@() }
    $m2 = Merge-ReviewFindings -Reviews @($r1,$rbad)
    Check 'G16 unparsed reviewer listed' (@($m2.unparsed) -contains 'r3' -and @($m2.merged).Count -eq 2)
    $m3 = Merge-ReviewFindings -Reviews @($rbad)
    Check 'G17 all-unparsed -> empty merged' (@($m3.merged).Count -eq 0)

    $vc = Get-AcceptanceVerdict -MergedFindings @(@{severity='critical';area='a';summary='b'})
    Check 'G18 critical -> reject' ($vc.verdict -eq 'reject' -and $vc.counts.critical -eq 1)
    $vp = Get-AcceptanceVerdict -MergedFindings @(@{severity='important';area='a';summary='b'})
    Check 'G19 important -> polish' ($vp.verdict -eq 'polish' -and $vp.counts.important -eq 1)
    $vm = Get-AcceptanceVerdict -MergedFindings @(@{severity='minor';area='a';summary='b'})
    Check 'G20 minor only -> accept' ($vm.verdict -eq 'accept' -and $vm.counts.minor -eq 1)
    $vn = Get-AcceptanceVerdict -MergedFindings @()
    Check 'G21 none -> accept, reason no findings' ($vn.verdict -eq 'accept' -and $vn.reason -match 'no findings')
    $vt = Get-AcceptanceVerdict -MergedFindings @(@{severity='minor';area='a';summary='b'}) -PolishAt 'minor'
    Check 'G22 tunable threshold: minor -> polish when PolishAt=minor' ($vt.verdict -eq 'polish')
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED"; exit 1 }
    Write-Host "`nALL PASS"
}
