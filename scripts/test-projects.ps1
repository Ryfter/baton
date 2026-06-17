#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/projects-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: pure mapping ----
    $decisive = @{ type='bug'; priority='P1'; estimate='M'; risk='medium'; area='routing'
                   recommended_platform='Codex'; confidence=0.9 }
    $labels = ConvertTo-SyncLabels -Triage $decisive
    Check 'T1 decisive labels include type:bug' ($labels -contains 'type:bug')
    Check 'T2 decisive labels include area:routing' ($labels -contains 'area:routing')
    Check 'T3 decisive labels include risk:medium' ($labels -contains 'risk:medium')
    Check 'T4 decisive labels include estimate:M' ($labels -contains 'estimate:M')
    Check 'T5 decisive labels include route:Codex' ($labels -contains 'route:Codex')

    $noArea = @{ type='docs'; priority='P3'; estimate='S'; risk='low'; area=$null; confidence=0.8 }
    Check 'T6 null area omitted' (-not (@(ConvertTo-SyncLabels -Triage $noArea) | Where-Object { $_ -like 'area:*' }))

    $fallback = @{ type='unknown'; priority='P3'; confidence=0.40 }
    Check 'T7 fallback -> needs-triage only' (@(ConvertTo-SyncLabels -Triage $fallback) -join ',' -eq 'needs-triage')

    $fields = ConvertTo-SyncFieldValues -Triage $decisive
    Check 'T8 decisive fields set Priority=P1' ($fields['Priority'] -eq 'P1')
    Check 'T9 decisive fields set Status=Todo' ($fields['Status'] -eq 'Todo')
    Check 'T10 fallback fields empty' ((ConvertTo-SyncFieldValues -Triage $fallback).Count -eq 0)

    $issTriaged   = [pscustomobject]@{ number=1; labels=@(@{name='type:bug'}, @{name='area:x'}) }
    $issUntriaged = [pscustomobject]@{ number=2; labels=@(@{name='needs-triage'}) }
    Check 'T11 issue with type:* is triaged' ((Get-IssueTriageState -Issue $issTriaged).triaged)
    Check 'T12 issue without type:* is untriaged' (-not (Get-IssueTriageState -Issue $issUntriaged).triaged)
    Check 'T13 existing labels captured' ((Get-IssueTriageState -Issue $issTriaged).existing_labels -contains 'type:bug')
}
finally {
    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "FAILED: $script:fail check(s)"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
}
