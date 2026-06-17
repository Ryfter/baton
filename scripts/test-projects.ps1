#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/projects-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("proj-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
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

    # ---- Task 3: gh I/O (stubbed gh) ----
    $script:ghCalls = @()
    $ghStub = {
        param($argv)
        $script:ghCalls += ,(@($argv))
        $global:LASTEXITCODE = 0
        $join = ($argv -join ' ')
        if ($join -like 'auth status*') { return }
        if ($join -like 'project field-list*') {
            return '{"fields":[{"id":"PF_sta","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"oT","name":"Todo"},{"id":"oP","name":"In Progress"}]},{"id":"PF_pri","name":"Priority","type":"ProjectV2SingleSelectField","options":[{"id":"o1","name":"P1"}]}]}'
        }
        if ($join -like 'project field-create*') { return '{"id":"PF_new"}' }
        if ($join -like 'project item-list*') {
            return '{"items":[{"id":"IT_11","content":{"type":"Issue","number":11},"status":"Todo","priority":"P2"}]}'
        }
        if ($join -like 'issue list*') {
            return '[{"number":11,"title":"t","body":"b","url":"https://x/11","labels":[{"name":"type:bug"}],"assignees":[]}]'
        }
        return ''
    }

    Check 'T23 Test-GhAuth true when authed' (Test-GhAuth -GhInvoker $ghStub)
    $ghUnauth = { param($argv) $global:LASTEXITCODE = 1 }
    Check 'T24 Test-GhAuth false when unauth' (-not (Test-GhAuth -GhInvoker $ghUnauth))

    $fm = Resolve-ProjectFields -Owner '@me' -ProjectNumber 7 -GhInvoker $ghStub
    Check 'T25 Resolve-ProjectFields maps Priority option id' ($fm['Priority'].options['P1'] -eq 'o1')
    Check 'T26 Resolve-ProjectFields maps Status field id' ($fm['Status'].id -eq 'PF_sta')

    $script:ghCalls = @()
    Ensure-ProjectFields -Owner '@me' -ProjectNumber 7 -FieldMap $fm -GhInvoker $ghStub | Out-Null
    Check 'T27 Ensure no-op when Priority present' (-not (@($script:ghCalls | Where-Object { ($_ -join ' ') -like 'project field-create*' }).Count))

    $script:ghCalls = @()
    Ensure-ProjectFields -Owner '@me' -ProjectNumber 7 -FieldMap @{ Status=@{id='PF_sta';options=@{Todo='oT'}} } -GhInvoker $ghStub | Out-Null
    $cre = @($script:ghCalls | Where-Object { ($_ -join ' ') -like 'project field-create*' })
    Check 'T28 Ensure creates Priority with options' (@($cre).Count -eq 1 -and (($cre[0] -join ' ') -match 'P0,P1,P2,P3,P4'))

    $items = Resolve-ProjectItems -Owner '@me' -ProjectNumber 7 -GhInvoker $ghStub
    Check 'T29 Resolve-ProjectItems maps number->item id' ($items['11'].item_id -eq 'IT_11')
    Check 'T30 Resolve-ProjectItems captures current field' ($items['11'].fields['Priority'] -eq 'P2')

    $iss = Get-RepoIssues -GhInvoker $ghStub
    Check 'T31 Get-RepoIssues returns parsed issues' (@($iss).Count -eq 1 -and $iss[0].number -eq 11)

    # ---- Task 4: Invoke-SyncPlan (apply, stubbed gh) ----
    $script:applyCalls = @()
    $applyStub = {
        param($argv)
        $script:applyCalls += ,(@($argv))
        $global:LASTEXITCODE = 0
        if (($argv -join ' ') -like 'project item-add*') { return '{"id":"IT_NEW"}' }
        return ''
    }
    $applyPlan = @(
        [pscustomobject]@{ number=20; url='https://x/20'; add_labels=@('type:bug','route:Codex'); add_to_project=$true
                           set_fields=@(@{ field='Priority'; field_id='PF_pri'; value='P1'; option_id='o1' }); skips=@() }
    )
    $res = Invoke-SyncPlan -Plan $applyPlan -Owner '@me' -ProjectNumber 7 -ProjectId 'PVT_x' -GhInvoker $applyStub
    Check 'T32 apply edits labels' (@($script:applyCalls | Where-Object { ($_ -join ' ') -match 'issue edit 20.*--add-label type:bug' }).Count -eq 1)
    Check 'T33 apply adds item to project' (@($script:applyCalls | Where-Object { ($_ -join ' ') -like 'project item-add 7*' }).Count -eq 1)
    Check 'T34 apply edits field with new item id' (@($script:applyCalls | Where-Object { ($_ -join ' ') -match 'item-edit .*--id IT_NEW.*--single-select-option-id o1' }).Count -eq 1)
    Check 'T35 apply records success' (@($res[0].applied).Count -ge 3 -and -not $res[0].error)

    $script:applyCalls = @()
    $failStub = {
        param($argv)
        $script:applyCalls += ,(@($argv))
        if (($argv -join ' ') -like 'issue edit 30*') { $global:LASTEXITCODE = 1; return }
        $global:LASTEXITCODE = 0
        if (($argv -join ' ') -like 'project item-add*') { return '{"id":"IT_X"}' }
        return ''
    }
    $plan2 = @(
        [pscustomobject]@{ number=30; url='u30'; add_labels=@('type:bug'); add_to_project=$false; set_fields=@(); skips=@() }
        [pscustomobject]@{ number=31; url='u31'; add_labels=@('type:docs'); add_to_project=$false; set_fields=@(); skips=@() }
    )
    $res2 = Invoke-SyncPlan -Plan $plan2 -Owner '@me' -ProjectNumber 7 -ProjectId 'PVT_x' -GhInvoker $failStub
    $r30 = $res2 | Where-Object { $_.number -eq 30 }
    $r31 = $res2 | Where-Object { $_.number -eq 31 }
    Check 'T36 failing issue recorded in failed' (@($r30.failed).Count -ge 1)
    Check 'T37 batch continues after a failure' (@($r31.applied | Where-Object { $_ -like 'labels:*' }).Count -eq 1)

    # ---- Task 5: CLI (child-process so its exit never aborts this suite) ----
    $cli = Join-Path $PSScriptRoot 'fleet-projects.ps1'
    Check 'T38 CLI file exists' (Test-Path $cli)

    $callLog = Join-Path $tmpDir 'ghcalls.txt'
    $env:BATON_PROJECTS_TEST_GH = $callLog
    if (Test-Path $callLog) { Remove-Item $callLog -Force }
    & pwsh -NoProfile -File $cli 'sync' '--owner' '@me' '--project' '7' *> $null
    $dryOk = $true
    if (Test-Path $callLog) {
        $mut = Get-Content $callLog | Where-Object { $_ -match 'issue edit|item-add|item-edit|field-create' }
        $dryOk = (@($mut).Count -eq 0)
    }
    Check 'T39 dry-run emits zero mutating gh calls' $dryOk
    Remove-Item Env:\BATON_PROJECTS_TEST_GH -ErrorAction SilentlyContinue
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "FAILED: $script:fail check(s)"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
}
