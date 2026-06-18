#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/research-gate-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: pure parse / escalation / fallback ----
    $adoptJson = '{"recommendation":"adopt","options":[{"name":"markitdown","kind":"library","fit":"strong","note":"doc->md"}],"rationale":"exists","next_action":"spike","confidence":0.82,"risk_if_wrong":"low"}'
    Check 'T1 json block extracted from prose' ((Get-GateJsonBlock -Raw ("noise " + $adoptJson + " tail")) -eq $adoptJson)
    Check 'T2 no json -> empty' ((Get-GateJsonBlock -Raw 'no braces here') -eq '')

    $v = ConvertTo-GateHashtable -RawStdout ('```json' + "`n" + $adoptJson + "`n" + '```')
    Check 'T3 fenced json parses recommendation' ($v.recommendation -eq 'adopt')
    Check 'T4 options normalized to array' (@($v.options).Count -eq 1)
    Check 'T5 escalation defaults injected' (($v.escalated -eq $false) -and ($v.ContainsKey('escalation_needed')))
    Check 'T6 garbage -> null' ($null -eq (ConvertTo-GateHashtable -RawStdout 'not json'))

    Check 'T7 low confidence escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.5; risk_if_wrong='low'; recommendation='adopt' })
    Check 'T8 high risk escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.9; risk_if_wrong='high'; recommendation='adopt' })
    Check 'T9 inconclusive escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.9; risk_if_wrong='low'; recommendation='inconclusive' })
    Check 'T10 confident low-risk adopt does not escalate' (-not (Test-GateEscalationNeeded -Verdict @{ confidence=0.85; risk_if_wrong='low'; recommendation='adopt' }))

    $fb = New-GateFallback -Reason 'no worker'
    Check 'T11 fallback is inconclusive' ($fb.recommendation -eq 'inconclusive')
    Check 'T12 fallback has no options' (@($fb.options).Count -eq 0)
    Check 'T13 fallback flagged for escalation' ($fb.escalation_needed -eq $true)
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
