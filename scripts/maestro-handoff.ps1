#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Maestro handoff + session registry CLI.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Subcommand,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest,
    [string]$Project,
    [string]$JobId,
    [string]$HerdrTarget,
    [string]$Provider = 'grok',
    [string]$Kind = 'grok',
    [string]$Goal,
    [string]$CurrentState,
    [string]$RelevantFiles,
    [string]$Constraints,
    [string]$DoneWhen,
    [string]$Checks,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-session-lib.ps1')

function Err([string]$m) { [Console]::Error.WriteLine($m); exit 2 }

if (-not $Subcommand) { Err 'usage: maestro-handoff <write|show|register|list> ...' }

switch ($Subcommand.ToLowerInvariant()) {
    'write' {
        if (-not $JobId -or -not $Goal) { Err 'write requires -JobId and -Goal' }
        $p = Write-MaestroHandoff -JobId $JobId -Goal $Goal -CurrentState $CurrentState `
            -RelevantFiles $RelevantFiles -Constraints $Constraints -DoneWhen $DoneWhen -Checks $Checks
        if ($Json) { @{ path = $p } | ConvertTo-Json } else { $p }
        exit 0
    }
    'show' {
        if (-not $JobId) { Err 'show requires -JobId' }
        $t = Read-MaestroHandoffText -JobId $JobId
        if (-not $t) { Err "no handoff for $JobId" }
        if ($Json) { @{ job_id = $JobId; body = $t } | ConvertTo-Json } else { Write-Host $t }
        exit 0
    }
    'register' {
        if (-not $Project -or -not $HerdrTarget) { Err 'register requires -Project and -HerdrTarget' }
        $s = Set-MaestroProjectSession -Project $Project -HerdrTarget $HerdrTarget -Provider $Provider -Kind $Kind
        if ($Json) { $s | ConvertTo-Json -Depth 4 } else { Write-Host "registered $Project -> $HerdrTarget" }
        exit 0
    }
    'list' {
        $reg = Get-MaestroSessionRegistry
        if ($Json) { $reg | ConvertTo-Json -Depth 6 } else {
            foreach ($p in $reg.projects.PSObject.Properties) {
                Write-Host ("{0}: herdr={1} provider={2} last={3}" -f $p.Name, $p.Value.herdr_target, $p.Value.provider, $p.Value.last_fired_at)
            }
        }
        exit 0
    }
    default { Err "unknown: $Subcommand" }
}
