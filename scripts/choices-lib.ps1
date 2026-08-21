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
    Set-ChoiceTimestampsIso -Choice $Choice
    Test-ChoiceSchema -Choice $Choice
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
    Set-ChoiceTimestampsIso -Choice $obj
    Test-ChoiceSchema -Choice $obj
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
