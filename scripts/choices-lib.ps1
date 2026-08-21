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

function Test-ChoiceSchema {
    param([Parameter(Mandatory)]$Choice)
    if ($null -eq $Choice) { throw 'choice is null' }
    $ver = [int]$Choice.schema_version
    if ($ver -ne $script:ChoiceSchemaVersion) {
        throw "unsupported schema_version: $ver (want $($script:ChoiceSchemaVersion))"
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
    return $obj
}
