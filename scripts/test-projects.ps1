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

    # ---- Task 2: Build-SyncPlan (pure) ----
    $fieldMap = @{
        Priority = @{ id='PF_pri'; type='ProjectV2SingleSelectField'; options=@{ P0='o0'; P1='o1'; P2='o2'; P3='o3'; P4='o4' } }
        Status   = @{ id='PF_sta'; type='ProjectV2SingleSelectField'; options=@{ Todo='oT'; 'In Progress'='oP'; Done='oD' } }
    }
    $issues = @(
        [pscustomobject]@{ number=10; url='https://x/10'; labels=@() }
        [pscustomobject]@{ number=11; url='https://x/11'; labels=@(@{name='type:bug'}) }
        [pscustomobject]@{ number=12; url='https://x/12'; labels=@() }
    )
    $triages = @{ '10' = @{ type='bug'; priority='P1'; estimate='M'; risk='low'; area='core'; recommended_platform='Codex'; confidence=0.9 } }
    $plan = Build-SyncPlan -Issues $issues -Triages $triages -FieldMap $fieldMap -ClassifyWorkers @{ '12'='haiku' }
    $p10 = $plan | Where-Object { $_.number -eq 10 }
    Check 'T14 classified issue adds type:bug' ($p10.add_labels -contains 'type:bug')
    Check 'T15 classified issue sets Priority field' (@($p10.set_fields | Where-Object { $_.field -eq 'Priority' -and $_.option_id -eq 'o1' }).Count -eq 1)
    Check 'T16 classified issue queued for add_to_project' ($p10.add_to_project)
    $p11 = $plan | Where-Object { $_.number -eq 11 }
    Check 'T17 already-triaged issue not reclassified' (@($p11.add_labels).Count -eq 0 -and ($p11.skips -join ' ') -match 'already triaged')
    $p12 = $plan | Where-Object { $_.number -eq 12 }
    Check 'T18 untriaged-undispatched shows would-be worker' ($p12.classify_worker -eq 'haiku')

    $plan2 = Build-SyncPlan -Issues @($issues[0]) -Triages $triages -FieldMap @{}
    $sk = ($plan2 | Where-Object { $_.number -eq 10 }).skips -join ' '
    Check 'T19 absent field -> skip reason' ($sk -match "field 'Priority' not found")

    $issDup = @([pscustomobject]@{ number=13; url='u'; labels=@(@{name='risk:low'}, @{name='area:core'}, @{name='estimate:M'}, @{name='route:Codex'}) })
    $triDup = @{ '13' = @{ type='bug'; priority='P1'; estimate='M'; risk='low'; area='core'; recommended_platform='Codex'; confidence=0.9 } }
    $pDup = Build-SyncPlan -Issues $issDup -Triages $triDup -FieldMap $fieldMap
    $pd = $pDup | Where-Object { $_.number -eq 13 }
    Check 'T20 present label -> skip not re-added' (($pd.add_labels -contains 'type:bug') -and -not ($pd.add_labels -contains 'risk:low'))

    $pCur = Build-SyncPlan -Issues @($issues[0]) -Triages $triages -FieldMap $fieldMap -CurrentFields @{ '10'=@{ Priority='P1' } }
    $pc = $pCur | Where-Object { $_.number -eq 10 }
    Check 'T21 already-correct field -> skip' ((($pc.skips -join ' ') -match "field 'Priority' already 'P1'") -and -not (@($pc.set_fields | Where-Object { $_.field -eq 'Priority' }).Count))

    $triFb = @{ '10' = @{ type='unknown'; priority='P3'; confidence=0.4 } }
    $pFb = (Build-SyncPlan -Issues @($issues[0]) -Triages $triFb -FieldMap $fieldMap) | Where-Object { $_.number -eq 10 }
    Check 'T22 fallback -> needs-triage label, no fields' (($pFb.add_labels -contains 'needs-triage') -and (@($pFb.set_fields).Count -eq 0))
}
finally {
    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "FAILED: $script:fail check(s)"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
}
