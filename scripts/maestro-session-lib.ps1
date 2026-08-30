#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Maestro session registry, cache-aware handoffs, and Herdr target resolution.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'baton-home.ps1')

function Get-MaestroRoot {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'maestro')
}

function Get-MaestroSessionRegistryPath {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path (Get-MaestroRoot -BatonHome $BatonHome) 'sessions.json')
}

function Get-MaestroHandoffsDir {
    param([string]$BatonHome = (Get-BatonHome))
    $dir = Join-Path (Get-MaestroRoot -BatonHome $BatonHome) 'handoffs'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return $dir
}

function Get-MaestroSessionRegistry {
    param([string]$BatonHome = (Get-BatonHome))
    $path = Get-MaestroSessionRegistryPath -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{ schema_version = 1; projects = @{} }
    }
    $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($null -eq $obj.projects) { $obj | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{}) -Force }
    return $obj
}

function Save-MaestroSessionRegistry {
    param(
        [Parameter(Mandatory)]$Registry,
        [string]$BatonHome = (Get-BatonHome)
    )
    $path = Get-MaestroSessionRegistryPath -BatonHome $BatonHome
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$path.tmp"
    ($Registry | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-MaestroProjectSession {
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$BatonHome = (Get-BatonHome)
    )
    $reg = Get-MaestroSessionRegistry -BatonHome $BatonHome
    $key = [string]$Project
    if ($reg.projects.PSObject.Properties[$key]) {
        return $reg.projects.$key
    }
    return $null
}

function Set-MaestroProjectSession {
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$HerdrTarget,
        [string]$Provider = 'openrouter-glm',
        [string]$Kind = 'openrouter',
        [string]$BatonHome = (Get-BatonHome)
    )
    $reg = Get-MaestroSessionRegistry -BatonHome $BatonHome
    if ($reg.projects -isnot [hashtable]) {
        $ht = @{}
        foreach ($p in $reg.projects.PSObject.Properties) { $ht[$p.Name] = $p.Value }
        $reg.projects = $ht
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $reg.projects[$Project] = [ordered]@{
        herdr_target  = $HerdrTarget
        provider      = $Provider
        kind          = $Kind
        last_fired_at = $now
        updated_at    = $now
    }
    Save-MaestroSessionRegistry -Registry $reg -BatonHome $BatonHome
    return $reg.projects[$Project]
}

function Resolve-MaestroHerdrTarget {
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$BatonHome = (Get-BatonHome)
    )
    if (-not [string]::IsNullOrWhiteSpace($env:HERDR_TARGET)) {
        return [string]$env:HERDR_TARGET
    }
    $sess = Get-MaestroProjectSession -Project $Project -BatonHome $BatonHome
    if ($sess -and -not [string]::IsNullOrWhiteSpace([string]$sess.herdr_target)) {
        return [string]$sess.herdr_target
    }
    return "maestro-$Project"
}

function Test-MaestroUseHerdr {
    param([Parameter(Mandatory)][string]$Project)
    if ($env:HERDR -eq '1') { return $true }
    if ($env:HERDR -eq '0') { return $false }
    $sess = Get-MaestroProjectSession -Project $Project
    if ($sess -and $sess.herdr_target) { return $true }
    return $false
}

function Get-MaestroHandoffPath {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$BatonHome = (Get-BatonHome)
    )
    return (Join-Path (Get-MaestroHandoffsDir -BatonHome $BatonHome) "$JobId.md")
}

function Format-MaestroHandoff {
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string]$CurrentState = '(describe branch, files touched, last run_id)',
        [string]$RelevantFiles = '(paths)',
        [string]$Constraints = '(do not change architecture unless asked)',
        [string]$DoneWhen = '(tests pass, PR ready, etc.)',
        [string]$Checks = '(commands to run before returning)'
    )
    $lines = @(
        '# Maestro handoff',
        '',
        '## Goal',
        $Goal,
        '',
        '## Current state',
        $CurrentState,
        '',
        '## Relevant files',
        $RelevantFiles,
        '',
        '## Constraints',
        $Constraints,
        '',
        '## Done when',
        $DoneWhen,
        '',
        '## Checks',
        $Checks,
        ''
    )
    return ($lines -join "`n")
}

function Write-MaestroHandoff {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Goal,
        [string]$CurrentState,
        [string]$RelevantFiles,
        [string]$Constraints,
        [string]$DoneWhen,
        [string]$Checks,
        [string]$BatonHome = (Get-BatonHome)
    )
    $body = Format-MaestroHandoff -Goal $Goal -CurrentState $CurrentState `
        -RelevantFiles $RelevantFiles -Constraints $Constraints -DoneWhen $DoneWhen -Checks $Checks
    $path = Get-MaestroHandoffPath -JobId $JobId -BatonHome $BatonHome
    Set-Content -LiteralPath $path -Value $body -Encoding utf8NoBOM
    return $path
}

function Read-MaestroHandoffText {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$BatonHome = (Get-BatonHome)
    )
    $path = Get-MaestroHandoffPath -JobId $JobId -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw)
}

function Expand-MaestroGoalWithHandoff {
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string]$JobId,
        [string]$BatonHome = (Get-BatonHome)
    )
    if (-not $JobId) { return $Goal }
    $handoff = Read-MaestroHandoffText -JobId $JobId -BatonHome $BatonHome
    if (-not $handoff) { return $Goal }
    return @(
        'Use the handoff below as authoritative project context. Do not assume prior conversation history.',
        '',
        $handoff,
        '',
        '## Task for this run',
        $Goal
    ) -join "`n"
}

function Update-MaestroSessionAfterFire {
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$Provider,
        [string]$BatonHome = (Get-BatonHome)
    )
    $sess = Get-MaestroProjectSession -Project $Project -BatonHome $BatonHome
    $target = Resolve-MaestroHerdrTarget -Project $Project -BatonHome $BatonHome
    $kind = if ($sess -and $sess.kind) { [string]$sess.kind } else { 'openrouter' }
    $prov = if ($Provider) { $Provider } elseif ($sess -and $sess.provider) { [string]$sess.provider } else { 'openrouter-glm' }
    Set-MaestroProjectSession -Project $Project -HerdrTarget $target -Provider $prov -Kind $kind -BatonHome $BatonHome | Out-Null
}
