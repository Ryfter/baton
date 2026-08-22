# scripts/choices-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'baton-home.ps1')

$script:ChoiceStatuses = @('draft', 'admitted', 'answered', 'rejected', 'superseded')
$script:ChoiceSchemaVersion = 1

function Get-ChoicesDir {
    param([string]$BatonHome = (Get-BatonHome))
    $dir = Join-Path $BatonHome 'choices'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return $dir
}

function New-ChoiceId {
    return ('ch-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Get-ChoicePath {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$BatonHome = (Get-BatonHome)
    )
    if ($Id -notmatch '^ch-[0-9a-f]{12}$') { throw "invalid choice id: $Id" }
    return (Join-Path (Get-ChoicesDir -BatonHome $BatonHome) "$Id.json")
}

function ConvertTo-ChoiceIsoTimestamp {
    param($Value)
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
            $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
        }
        return $dt.ToUniversalTime().ToString('o')
    }
    if ($Value -is [datetimeoffset]) {
        return ([datetimeoffset]$Value).ToUniversalTime().ToString('o')
    }
    return [string]$Value
}

function Set-ChoiceTimestampsIso {
    param($Choice)
    $Choice.created_at = ConvertTo-ChoiceIsoTimestamp -Value $Choice.created_at
    $Choice.updated_at = ConvertTo-ChoiceIsoTimestamp -Value $Choice.updated_at
    if ($null -ne $Choice.PSObject.Properties['admitted_at']) {
        $Choice.admitted_at = ConvertTo-ChoiceIsoTimestamp -Value $Choice.admitted_at
    }
    if ($null -ne $Choice.PSObject.Properties['answered_at']) {
        $Choice.answered_at = ConvertTo-ChoiceIsoTimestamp -Value $Choice.answered_at
    }
}

function Test-ChoiceSchemaVersion {
    param($Value)
    if ($Value -is [int] -or $Value -is [long]) {
        return ($Value -eq $script:ChoiceSchemaVersion)
    }
    return $false
}

function Test-ChoiceSchema {
    param([Parameter(Mandatory)]$Choice)
    if ($null -eq $Choice) { throw 'choice is null' }
    if (-not (Test-ChoiceSchemaVersion -Value $Choice.schema_version)) {
        throw "unsupported schema_version: $($Choice.schema_version) (want $($script:ChoiceSchemaVersion))"
    }
    $st = [string]$Choice.status
    if ($st -notin $script:ChoiceStatuses) { throw "invalid status: $st" }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.id)) { throw 'id required' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.project)) { throw 'project required' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.title)) { throw 'title required' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.question)) { throw 'question required' }
    $opts = @($Choice.options)
    if ($opts.Count -lt 2) { throw 'options must have at least 2 entries' }
    foreach ($o in $opts) {
        if ([string]::IsNullOrWhiteSpace([string]$o.id)) { throw 'option.id required' }
        if ([string]::IsNullOrWhiteSpace([string]$o.label)) { throw 'option.label required' }
    }
    if ($null -eq $Choice.recommendation -or
        [string]::IsNullOrWhiteSpace([string]$Choice.recommendation.option_id)) {
        throw 'recommendation.option_id required'
    }
    if ($null -eq $Choice.evidence) { throw 'evidence required (may be empty array)' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.created_at)) { throw 'created_at required' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.updated_at)) { throw 'updated_at required' }
    if ($st -in @('admitted', 'answered', 'rejected', 'superseded')) {
        if ([string]$Choice.priority -notin @('P0', 'P1', 'P2')) {
            throw "priority P0|P1|P2 required when status=$st"
        }
    }
}

function Write-Choice {
    param(
        [Parameter(Mandatory)]$Choice,
        [string]$BatonHome = (Get-BatonHome)
    )
    Test-ChoiceSchema -Choice $Choice
    Set-ChoiceTimestampsIso -Choice $Choice
    $path = Get-ChoicePath -Id ([string]$Choice.id) -BatonHome $BatonHome
    $tmp = "$path.tmp"
    $json = ($Choice | ConvertTo-Json -Depth 8)
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Read-Choice {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$BatonHome = (Get-BatonHome)
    )
    $path = Get-ChoicePath -Id $Id -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $path)) { throw "choice not found: $Id" }
    $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Test-ChoiceSchema -Choice $obj
    Set-ChoiceTimestampsIso -Choice $obj
    return $obj
}

function New-ChoiceDraft {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][object[]]$Options,
        [Parameter(Mandatory)][string]$RecommendationOptionId,
        [Parameter(Mandatory)][string]$RecommendationWhy,
        [object[]]$Evidence = @(),
        [string]$Blocks,
        [string]$BatonHome = (Get-BatonHome)
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $id = New-ChoiceId
    $choice = [ordered]@{
        schema_version = $script:ChoiceSchemaVersion
        id             = $id
        status         = 'draft'
        project        = $Project
        title          = $Title
        question       = $Question
        options        = @($Options)
        recommendation = @{ option_id = $RecommendationOptionId; why = $RecommendationWhy }
        evidence       = @($Evidence)
        created_at     = $now
        updated_at     = $now
    }
    if (-not [string]::IsNullOrWhiteSpace($Blocks)) { $choice.blocks = $Blocks }
    [void](Write-Choice -Choice $choice -BatonHome $BatonHome)
    return (Read-Choice -Id $id -BatonHome $BatonHome)
}

function Set-ChoiceAdmitted {
    param(
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet('P0','P1','P2')][string]$Priority = 'P1',
        [string]$BatonHome = (Get-BatonHome)
    )
    $c = Read-Choice -Id $Id -BatonHome $BatonHome
    if ([string]$c.status -ne 'draft') { throw "admit requires draft; got $($c.status)" }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $c | Add-Member -NotePropertyName status -NotePropertyValue 'admitted' -Force
    $c | Add-Member -NotePropertyName priority -NotePropertyValue $Priority -Force
    $c | Add-Member -NotePropertyName admitted_at -NotePropertyValue $now -Force
    $c | Add-Member -NotePropertyName updated_at -NotePropertyValue $now -Force
    [void](Write-Choice -Choice $c -BatonHome $BatonHome)
    return (Read-Choice -Id $Id -BatonHome $BatonHome)
}

function Set-ChoiceRejected {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$BatonHome = (Get-BatonHome)
    )
    $c = Read-Choice -Id $Id -BatonHome $BatonHome
    if ([string]$c.status -notin @('draft', 'admitted')) {
        throw "reject requires draft|admitted; got $($c.status)"
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ([string]::IsNullOrWhiteSpace([string]$c.priority)) {
        $c | Add-Member -NotePropertyName priority -NotePropertyValue 'P1' -Force
    }
    $c | Add-Member -NotePropertyName status -NotePropertyValue 'rejected' -Force
    $c | Add-Member -NotePropertyName updated_at -NotePropertyValue $now -Force
    [void](Write-Choice -Choice $c -BatonHome $BatonHome)
    return (Read-Choice -Id $Id -BatonHome $BatonHome)
}

function Set-ChoiceAnswered {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$OptionId,
        [string]$FreeText,
        [string]$Note,
        [string]$BatonHome = (Get-BatonHome)
    )
    $choice = Read-Choice -Id $Id -BatonHome $BatonHome
    if ([string]$choice.status -ne 'admitted') {
        throw "answer requires admitted; got $($choice.status)"
    }

    $hasOption = -not [string]::IsNullOrWhiteSpace($OptionId)
    $hasFreeText = -not [string]::IsNullOrWhiteSpace($FreeText)
    if (-not $hasOption -and -not $hasFreeText) {
        throw 'answer requires option_id or non-empty free_text'
    }
    if ($hasOption -and $OptionId -notin @($choice.options | ForEach-Object { [string]$_.id })) {
        throw "unknown option_id for $Id`: $OptionId"
    }

    $answer = [ordered]@{}
    if ($hasOption) { $answer.option_id = $OptionId }
    if ($hasFreeText) { $answer.free_text = $FreeText }
    if (-not [string]::IsNullOrWhiteSpace($Note)) { $answer.note = $Note }

    $now = ConvertTo-ChoiceIsoTimestamp -Value ([datetime]::UtcNow)
    $choice | Add-Member -NotePropertyName answer -NotePropertyValue $answer -Force
    $choice | Add-Member -NotePropertyName status -NotePropertyValue 'answered' -Force
    $choice | Add-Member -NotePropertyName answered_at -NotePropertyValue $now -Force
    $choice | Add-Member -NotePropertyName updated_at -NotePropertyValue $now -Force
    [void](Write-Choice -Choice $choice -BatonHome $BatonHome)
    return (Read-Choice -Id $Id -BatonHome $BatonHome)
}

function Get-ChoicePriorityRank {
    param([string]$Priority)
    switch ($Priority) {
        'P0' { return 0 }
        'P1' { return 1 }
        'P2' { return 2 }
        default { return 3 }
    }
}

function ConvertTo-ChoiceSortTimestamp {
    param(
        $Value,
        [string]$FieldName = 'timestamp'
    )
    if ($Value -is [datetimeoffset]) { return [datetimeoffset]$Value }
    if ($Value -is [datetime]) { return [datetimeoffset]([datetime]$Value) }

    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )
    if (-not $ok) { throw "invalid $FieldName timestamp: $Value" }
    return $parsed
}

function Get-Choices {
    param(
        [string]$BatonHome = (Get-BatonHome),
        [string]$Project,
        [string]$Status
    )
    $choices = @()
    $files = @(Get-ChildItem -LiteralPath (Get-ChoicesDir -BatonHome $BatonHome) `
        -Filter 'ch-*.json' -File)
    foreach ($file in $files) {
        try {
            $choice = Read-Choice -Id $file.BaseName -BatonHome $BatonHome
        } catch {
            Write-Warning "Skipping corrupt choice file '$($file.Name)': $($_.Exception.Message)"
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($Project) -and
            [string]$choice.project -ne $Project) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($Status) -and
            [string]$choice.status -ne $Status) {
            continue
        }
        $choices += $choice
    }

    return @($choices | Sort-Object `
        @{ Expression = { Get-ChoicePriorityRank -Priority ([string]$_.priority) } }, `
        @{ Expression = {
            if ([string]::IsNullOrWhiteSpace([string]$_.admitted_at)) {
                [datetimeoffset]::MaxValue
            } else {
                ConvertTo-ChoiceSortTimestamp -Value $_.admitted_at -FieldName 'admitted_at'
            }
        } }, `
        @{ Expression = { [string]$_.id } })
}

function Get-AdmittedProjectOrder {
    param([string]$BatonHome = (Get-BatonHome))
    $projectRanks = foreach ($group in @(
        Get-Choices -BatonHome $BatonHome -Status 'admitted' | Group-Object project
    )) {
        $bestChoice = @($group.Group | Sort-Object `
            @{ Expression = { Get-ChoicePriorityRank -Priority ([string]$_.priority) } }, `
            @{ Expression = {
                ConvertTo-ChoiceSortTimestamp -Value $_.admitted_at -FieldName 'admitted_at'
            } })[0]
        [pscustomobject]@{
            project     = [string]$group.Name
            rank        = Get-ChoicePriorityRank -Priority ([string]$bestChoice.priority)
            admitted_at = ConvertTo-ChoiceSortTimestamp `
                -Value $bestChoice.admitted_at -FieldName 'admitted_at'
        }
    }

    return @($projectRanks | Sort-Object rank, admitted_at, project |
        ForEach-Object { $_.project })
}

function Get-ChoicesCursorPath {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path (Get-ChoicesDir -BatonHome $BatonHome) '_cursor.json')
}

function Get-Cursor {
    param([string]$BatonHome = (Get-BatonHome))
    $path = Get-ChoicesCursorPath -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $cursor = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if (-not (Test-ChoiceSchemaVersion -Value $cursor.schema_version)) {
        throw "unsupported cursor schema_version: $($cursor.schema_version)"
    }
    return $cursor
}

function Set-Cursor {
    param(
        [Parameter(Mandatory)]$Cursor,
        [string]$BatonHome = (Get-BatonHome)
    )
    $stored = [ordered]@{
        schema_version = [int]$script:ChoiceSchemaVersion
        active_project = if ($null -eq $Cursor.active_project) {
            $null
        } else {
            [string]$Cursor.active_project
        }
        current_id     = if ($null -eq $Cursor.current_id) {
            $null
        } else {
            [string]$Cursor.current_id
        }
        project_order  = @($Cursor.project_order | ForEach-Object { [string]$_ })
    }
    $path = Get-ChoicesCursorPath -BatonHome $BatonHome
    $tmp = "$path.tmp"
    $stored | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Reset-ChoicesBriefCursor {
    param([string]$BatonHome = (Get-BatonHome))
    $order = @(Get-AdmittedProjectOrder -BatonHome $BatonHome)
    $activeProject = if ($order.Count -gt 0) { $order[0] } else { $null }
    $firstChoice = if ($null -ne $activeProject) {
        @(Get-Choices -BatonHome $BatonHome -Project $activeProject -Status 'admitted')[0]
    } else {
        $null
    }
    $cursor = [pscustomobject]@{
        schema_version = [int]$script:ChoiceSchemaVersion
        active_project = $activeProject
        current_id     = if ($null -ne $firstChoice) { $firstChoice.id } else { $null }
        project_order  = $order
    }
    Set-Cursor -Cursor $cursor -BatonHome $BatonHome
    return (Get-Cursor -BatonHome $BatonHome)
}

function Get-NextAdmittedChoice {
    param([string]$BatonHome = (Get-BatonHome))
    $cursor = Get-Cursor -BatonHome $BatonHome
    if ($null -eq $cursor) {
        $cursor = Reset-ChoicesBriefCursor -BatonHome $BatonHome
    }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$cursor.current_id)) {
            $current = @(Get-Choices -BatonHome $BatonHome -Status 'admitted' |
                Where-Object { $_.id -eq $cursor.current_id })
            if ($current.Count -gt 0) { return $current[0] }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$cursor.active_project)) {
            $inProject = @(Get-Choices -BatonHome $BatonHome `
                -Project $cursor.active_project -Status 'admitted')
            if ($inProject.Count -gt 0) {
                $cursor.current_id = $inProject[0].id
                Set-Cursor -Cursor $cursor -BatonHome $BatonHome
                return $inProject[0]
            }
        }

        $order = @($cursor.project_order)
        $activeIndex = [array]::IndexOf($order, [string]$cursor.active_project)
        for ($index = $activeIndex + 1; $index -lt $order.Count; $index++) {
            $nextProject = [string]$order[$index]
            $inProject = @(Get-Choices -BatonHome $BatonHome `
                -Project $nextProject -Status 'admitted')
            if ($inProject.Count -gt 0) {
                $cursor.active_project = $nextProject
                $cursor.current_id = $inProject[0].id
                Set-Cursor -Cursor $cursor -BatonHome $BatonHome
                return $inProject[0]
            }
        }

        if ($attempt -eq 0 -and
            @(Get-Choices -BatonHome $BatonHome -Status 'admitted').Count -gt 0) {
            $cursor = Reset-ChoicesBriefCursor -BatonHome $BatonHome
            continue
        }

        break
    }

    $cursor.active_project = $null
    $cursor.current_id = $null
    Set-Cursor -Cursor $cursor -BatonHome $BatonHome
    return $null
}

function Move-ChoiceCursorAfterAnswer {
    param([string]$BatonHome = (Get-BatonHome))
    $cursor = Get-Cursor -BatonHome $BatonHome
    if ($null -eq $cursor) {
        return (Get-NextAdmittedChoice -BatonHome $BatonHome)
    }
    $cursor.current_id = $null
    Set-Cursor -Cursor $cursor -BatonHome $BatonHome
    return (Get-NextAdmittedChoice -BatonHome $BatonHome)
}

function Format-ChoiceCard {
    param([Parameter(Mandatory)]$Choice)

    $evidence = @($Choice.evidence | ForEach-Object { [string]$_ })
    $evidenceText = if ($evidence.Count -gt 0) { $evidence -join ', ' } else { '(none)' }
    $blocksText = if ([string]::IsNullOrWhiteSpace([string]$Choice.blocks)) {
        '(none)'
    } else {
        [string]$Choice.blocks
    }

    $lines = @(
        "[$($Choice.id)] $($Choice.project) · $($Choice.priority) · $($Choice.status)"
        [string]$Choice.title
        [string]$Choice.question
        ''
        'Options:'
    )
    foreach ($option in @($Choice.options)) {
        $lines += "  [$($option.id)] $($option.label) — $($option.summary)"
    }
    $lines += @(
        ''
        "Recommended: $($Choice.recommendation.option_id) — $($Choice.recommendation.why)"
        "Evidence: $evidenceText"
        "Blocks: $blocksText"
    )
    return ($lines -join "`n")
}

function Format-ChoicesBrief {
    param([string]$BatonHome = (Get-BatonHome))

    $lines = @()
    foreach ($project in @(Get-AdmittedProjectOrder -BatonHome $BatonHome)) {
        $lines += "## $project"
        $lines += ''
        foreach ($choice in @(
            Get-Choices -BatonHome $BatonHome -Project $project -Status 'admitted'
        )) {
            $lines += Format-ChoiceCard -Choice $choice
            $lines += ''
        }
    }
    if ($lines.Count -eq 0) { return 'No admitted choices.' }
    return ($lines[0..($lines.Count - 2)] -join "`n")
}
