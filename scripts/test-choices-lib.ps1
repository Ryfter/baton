#!/usr/bin/env pwsh
# scripts/test-choices-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'baton-home.ps1')
. (Join-Path $PSScriptRoot 'choices-lib.ps1')

$script:failures = 0
function Assert([string]$label, [bool]$cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$prev = $env:BATON_HOME
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("baton-choices-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:BATON_HOME = $tmp
try {
    $dir = Get-ChoicesDir -BatonHome $tmp
    Assert 'T1 choices dir path ends with choices' ($dir -match '[\\/]choices$')
    Assert 'T1b dir created on Get-ChoicesDir' (Test-Path -LiteralPath $dir)

    $id = New-ChoiceId
    Assert 'T2 id prefix ch-' ($id -match '^ch-[0-9a-f]{12}$')

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $good = [ordered]@{
        schema_version = 1
        id             = $id
        status         = 'draft'
        project        = 'canvas-toolchain'
        title          = 'Publish v2.2.0?'
        question       = 'Unblock npm publish?'
        options        = @(
            @{ id = 'yes'; label = 'Publish'; summary = 'Tag and publish' }
            @{ id = 'no'; label = 'Defer'; summary = 'Wait' }
        )
        recommendation = @{ option_id = 'yes'; why = 'Professors blocked' }
        evidence       = @('docs/foo.md')
        created_at     = $now
        updated_at     = $now
    }
    $path = Write-Choice -Choice $good -BatonHome $tmp
    Assert 'T3 file written' (Test-Path -LiteralPath $path)
    $back = Read-Choice -Id $id -BatonHome $tmp
    Assert 'T4 round-trip id' ($back.id -eq $id)
    Assert 'T5 round-trip status' ($back.status -eq 'draft')
    Assert 'T5b created_at stays string' ($back.created_at -is [string])
    Assert 'T5c updated_at stays string' ($back.updated_at -is [string])

    $threw = $false
    try {
        $badHash = [ordered]@{}
        foreach ($p in $good.Keys) { $badHash[$p] = $good[$p] }
        $badHash.status = 'waiting'
        Test-ChoiceSchema -Choice $badHash
    } catch { $threw = $true }
    Assert 'T6 unknown status throws' $threw

    $threw2 = $false
    try {
        $badVer = [ordered]@{}
        foreach ($p in $good.Keys) { $badVer[$p] = $good[$p] }
        $badVer.schema_version = 99
        Test-ChoiceSchema -Choice $badVer
    } catch { $threw2 = $true }
    Assert 'T7 bad schema_version throws' $threw2

    $threw3 = $false
    try {
        $badVerFloat = [ordered]@{}
        foreach ($p in $good.Keys) { $badVerFloat[$p] = $good[$p] }
        $badVerFloat.schema_version = 1.1
        Test-ChoiceSchema -Choice $badVerFloat
    } catch { $threw3 = $true }
    Assert 'T8 coercible schema_version 1.1 throws' $threw3

    $threw4 = $false
    try {
        $badVerStr = [ordered]@{}
        foreach ($p in $good.Keys) { $badVerStr[$p] = $good[$p] }
        $badVerStr.schema_version = '1'
        Test-ChoiceSchema -Choice $badVerStr
    } catch { $threw4 = $true }
    Assert 'T9 string schema_version "1" throws' $threw4

    $writeSchemaError = ''
    try {
        Write-Choice -Choice ([pscustomobject]@{ schema_version = 99 }) -BatonHome $tmp
    } catch {
        $writeSchemaError = $_.Exception.Message
    }
    Assert 'T9b write validates schema before normalizing missing timestamps' (
        $writeSchemaError -match '^unsupported schema_version:'
    )

    $d = New-ChoiceDraft `
        -Project 'bookprofile' `
        -Title 'A/B/C surface' `
        -Question 'Public, personal, or hybrid?' `
        -Options @(
            @{ id = 'a'; label = 'Public'; summary = 'Static only' }
            @{ id = 'b'; label = 'Personal'; summary = 'Local only' }
            @{ id = 'c'; label = 'Hybrid'; summary = 'Local then publish' }
        ) `
        -RecommendationOptionId 'c' `
        -RecommendationWhy 'Match free stack + share later' `
        -Evidence @('BookProfile/docs/...') `
        -Blocks 'bp-scaffold' `
        -BatonHome $tmp
    Assert 'T10 draft status' ($d.status -eq 'draft')
    Assert 'T10b blocks set' ($d.blocks -eq 'bp-scaffold')

    $a = Set-ChoiceAdmitted -Id $d.id -Priority 'P0' -BatonHome $tmp
    Assert 'T11 admitted' ($a.status -eq 'admitted')
    Assert 'T11b priority P0' ($a.priority -eq 'P0')
    Assert 'T11c admitted_at set' (-not [string]::IsNullOrWhiteSpace([string]$a.admitted_at))
    Assert 'T11d admitted_at stays string' ($a.admitted_at -is [string])

    $threwAdmit = $false
    try { Set-ChoiceAdmitted -Id $d.id -BatonHome $tmp } catch { $threwAdmit = $true }
    Assert 'T12 double admit throws' $threwAdmit

    $d2 = New-ChoiceDraft -Project 'x' -Title 't' -Question 'q' `
        -Options @(@{id='a';label='A';summary='a'},@{id='b';label='B';summary='b'}) `
        -RecommendationOptionId 'a' -RecommendationWhy 'w' -Evidence @() -BatonHome $tmp
    $r = Set-ChoiceRejected -Id $d2.id -BatonHome $tmp
    Assert 'T13 rejected' ($r.status -eq 'rejected')
    Assert 'T13b reject-from-draft assigns P1' ($r.priority -eq 'P1')

    $tmp3 = Join-Path $tmp 'task-3'
    New-Item -ItemType Directory -Force -Path $tmp3 | Out-Null
    function New-TestAdmitted([string]$project, [string]$priority, [datetime]$when) {
        $draft = New-ChoiceDraft -Project $project -Title "$project $priority" -Question 'q' `
            -Options @(@{id='a';label='A';summary='a'},@{id='b';label='B';summary='b'}) `
            -RecommendationOptionId 'a' -RecommendationWhy 'w' -Evidence @() -BatonHome $tmp3
        $choice = Set-ChoiceAdmitted -Id $draft.id -Priority $priority -BatonHome $tmp3
        $choice.admitted_at = $when.ToUniversalTime().ToString('o')
        $choice.updated_at = $choice.admitted_at
        [void](Write-Choice -Choice $choice -BatonHome $tmp3)
        return $choice
    }

    $t0 = [datetime]'2026-08-21T10:00:00Z'
    $t1 = [datetime]'2026-08-21T11:00:00Z'
    $t2 = [datetime]'2026-08-21T12:00:00Z'
    $bp = New-TestAdmitted 'bookprofile' 'P1' $t1
    $ct = New-TestAdmitted 'canvas-toolchain' 'P0' $t2
    $af = New-TestAdmitted 'atomicforge' 'P0' $t0
    $afP1 = New-TestAdmitted 'atomicforge' 'P1' ([datetime]'2026-08-20T09:00:00Z')
    [void](New-ChoiceDraft -Project 'atomicforge' -Title 'draft ignored' -Question 'q' `
        -Options @(@{id='a';label='A';summary='a'},@{id='b';label='B';summary='b'}) `
        -RecommendationOptionId 'a' -RecommendationWhy 'w' -Evidence @() -BatonHome $tmp3)
    Set-Content -LiteralPath (Join-Path (Get-ChoicesDir -BatonHome $tmp3) 'not-a-choice.json') `
        -Value '{ invalid json' -Encoding utf8NoBOM

    $corruptName = 'ch-deadbeefcafe.json'
    $corruptPath = Join-Path (Get-ChoicesDir -BatonHome $tmp3) $corruptName
    Set-Content -LiteralPath $corruptPath -Value '{"schema_version":99}' -Encoding utf8NoBOM
    $readSchemaError = ''
    try {
        Read-Choice -Id 'ch-deadbeefcafe' -BatonHome $tmp3
    } catch {
        $readSchemaError = $_.Exception.Message
    }
    Assert 'T13c read validates schema before normalizing missing timestamps' (
        $readSchemaError -match '^unsupported schema_version:'
    )

    $listOutput = @(Get-Choices -BatonHome $tmp3 -Status 'admitted' 3>&1)
    $corruptWarnings = @($listOutput |
        Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    $admitted = @($listOutput |
        Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
    Assert 'T14 list scans only choice files' ($admitted.Count -eq 4)
    Assert 'T14a corrupt choice file is skipped with filename warning' (
        $corruptWarnings.Count -eq 1 -and
        [string]$corruptWarnings[0] -match [regex]::Escape($corruptName)
    )
    Remove-Item -LiteralPath $corruptPath
    $atomic = @(Get-Choices -BatonHome $tmp3 -Project 'atomicforge' -Status 'admitted')
    Assert 'T14b project and status filters apply' ($atomic.Count -eq 2)
    Assert 'T14c within project priority wins over age' (
        $atomic[0].id -eq $af.id -and $atomic[1].id -eq $afP1.id
    )

    $order = @(Get-AdmittedProjectOrder -BatonHome $tmp3)
    Assert 'T15 P0 projects before P1' ($order[-1] -eq 'bookprofile')
    Assert 'T15b older best-priority admission breaks project tie' (
        $order[0] -eq 'atomicforge' -and $order[1] -eq 'canvas-toolchain'
    )

    $cursor = Reset-ChoicesBriefCursor -BatonHome $tmp3
    Assert 'T16 reset selects first project and card' (
        $cursor.active_project -eq 'atomicforge' -and $cursor.current_id -eq $af.id
    )
    $cursorBack = Get-Cursor -BatonHome $tmp3
    Assert 'T16b cursor round trip has integer schema 1' (
        $cursorBack.schema_version -in @([int]1, [long]1) -and
        $cursorBack.schema_version -isnot [string]
    )
    $next = Get-NextAdmittedChoice -BatonHome $tmp3
    Assert 'T17 next returns still-admitted current card' ($next.id -eq $af.id)

    $cursorBeforeAnswer = (Get-Cursor -BatonHome $tmp3 | ConvertTo-Json -Depth 4 -Compress)
    $ans = Set-ChoiceAnswered -Id $af.id -OptionId 'a' -Note 'approved' -BatonHome $tmp3
    Assert 'T18 answer sets status and option' (
        $ans.status -eq 'answered' -and
        $ans.answer.option_id -eq 'a' -and
        $ans.answer.note -eq 'approved'
    )
    $answeredAt = [datetimeoffset]::MinValue
    Assert 'T18b answer timestamps are persisted ISO strings' (
        $ans.answered_at -is [string] -and
        [datetimeoffset]::TryParse([string]$ans.answered_at, [ref]$answeredAt) -and
        $ans.updated_at -eq $ans.answered_at
    )
    Assert 'T18c answering does not move cursor' (
        (Get-Cursor -BatonHome $tmp3 | ConvertTo-Json -Depth 4 -Compress) -eq $cursorBeforeAnswer
    )

    $threwOpt = $false
    try { Set-ChoiceAnswered -Id $ct.id -OptionId 'nope' -BatonHome $tmp3 } catch { $threwOpt = $true }
    Assert 'T19 unknown option throws' $threwOpt

    $threwEmpty = $false
    try { Set-ChoiceAnswered -Id $ct.id -FreeText '  ' -BatonHome $tmp3 } catch { $threwEmpty = $true }
    Assert 'T19b empty answer throws' $threwEmpty

    $threwStatus = $false
    try { Set-ChoiceAnswered -Id $af.id -OptionId 'a' -BatonHome $tmp3 } catch { $threwStatus = $true }
    Assert 'T19c answer requires admitted status' $threwStatus

    $afterFirst = Move-ChoiceCursorAfterAnswer -BatonHome $tmp3
    Assert 'T20 cursor stays on project while admitted remain' (
        $afterFirst.id -eq $afP1.id -and (Get-Cursor -BatonHome $tmp3).active_project -eq 'atomicforge'
    )

    $textAnswer = Set-ChoiceAnswered -Id $afP1.id -FreeText 'Use the staged rollout' -BatonHome $tmp3
    Assert 'T21 free-text answer persists' (
        $textAnswer.answer.free_text -eq 'Use the staged rollout' -and
        $null -eq $textAnswer.answer.PSObject.Properties['option_id']
    )
    $afterProject = Move-ChoiceCursorAfterAnswer -BatonHome $tmp3
    Assert 'T22 cursor advances after project clears' (
        $afterProject.id -eq $ct.id -and (Get-Cursor -BatonHome $tmp3).active_project -eq 'canvas-toolchain'
    )

    $card = Format-ChoiceCard -Choice $a
    Assert 'T23 card contains header, body, and option detail' (
        $card -match "\[$([regex]::Escape($a.id))\] bookprofile · P0 · admitted" -and
        $card -match 'A/B/C surface' -and
        $card -match '(?m)^  \[a\] Public — Static only$'
    )
    Assert 'T23b card contains recommendation, evidence, and blocks' (
        $card -match '(?m)^Recommended: c — Match free stack \+ share later$' -and
        $card -match '(?m)^Evidence: BookProfile/docs/\.\.\.$' -and
        $card -match '(?m)^Blocks: bp-scaffold$'
    )

    $cursorBeforeBrief = (Get-Cursor -BatonHome $tmp3 | ConvertTo-Json -Depth 4 -Compress)
    $brief = Format-ChoicesBrief -BatonHome $tmp3
    Assert 'T24 brief groups admitted projects in queue order' (
        $brief -match '(?m)^## canvas-toolchain$' -and
        $brief -match '(?m)^## bookprofile$' -and
        $brief.IndexOf('## canvas-toolchain') -lt $brief.IndexOf('## bookprofile')
    )
    Assert 'T24b brief excludes projects with no admitted cards' (
        $brief -notmatch '(?m)^## atomicforge$'
    )
    Assert 'T24c brief is a pure read of cursor state' (
        (Get-Cursor -BatonHome $tmp3 | ConvertTo-Json -Depth 4 -Compress) -eq $cursorBeforeBrief
    )

    $tmp4 = Join-Path $tmp 'stale-cursor'
    New-Item -ItemType Directory -Force -Path $tmp4 | Out-Null
    $oldDraft = New-ChoiceDraft -Project 'old-project' -Title 'old' -Question 'q' `
        -Options @(@{id='a';label='A';summary='a'},@{id='b';label='B';summary='b'}) `
        -RecommendationOptionId 'a' -RecommendationWhy 'w' -Evidence @() -BatonHome $tmp4
    $oldChoice = Set-ChoiceAdmitted -Id $oldDraft.id -Priority 'P1' -BatonHome $tmp4
    [void](Reset-ChoicesBriefCursor -BatonHome $tmp4)
    [void](Set-ChoiceAnswered -Id $oldChoice.id -OptionId 'a' -BatonHome $tmp4)

    $newDraft = New-ChoiceDraft -Project 'new-project' -Title 'new' -Question 'q' `
        -Options @(@{id='a';label='A';summary='a'},@{id='b';label='B';summary='b'}) `
        -RecommendationOptionId 'a' -RecommendationWhy 'w' -Evidence @() -BatonHome $tmp4
    $newChoice = Set-ChoiceAdmitted -Id $newDraft.id -Priority 'P0' -BatonHome $tmp4
    $fromStaleCursor = Get-NextAdmittedChoice -BatonHome $tmp4
    $refreshedCursor = Get-Cursor -BatonHome $tmp4
    Assert 'T25 stale cursor refresh finds newly admitted project' (
        $fromStaleCursor.id -eq $newChoice.id -and
        $refreshedCursor.active_project -eq 'new-project' -and
        $refreshedCursor.current_id -eq $newChoice.id
    )
}
finally {
    if ($null -eq $prev) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prev }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { Write-Host "FAILED: $failures"; exit 1 }
Write-Host 'ALL PASS'
exit 0
