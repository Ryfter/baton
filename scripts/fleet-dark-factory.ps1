#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:dark-factory — seed Level-4 overnight lanes (dashboard, spine, grimdex-edu).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('seed', 'status', 'night')][string]$Action = 'seed',
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [switch]$Admit,
    [switch]$Fire,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dark-factory-lib.ps1')

switch ($Action) {
    'status' {
        $out = Get-DarkFactoryStatus -BatonHome $BatonHome
    }
    'night' {
        $seed = Invoke-DarkFactorySeed -BatonHome $BatonHome -Admit
        $admitScript = Join-Path $PSScriptRoot 'maestro-admit.ps1'
        & pwsh -NoProfile -File $admitScript -BatonHome $BatonHome | Out-Null
        $fireOut = $null
        if ($Fire) {
            $fireScript = Join-Path $PSScriptRoot 'maestro-fire.ps1'
            if (Test-Path -LiteralPath $fireScript) {
                & pwsh -NoProfile -File $fireScript -BatonHome $BatonHome | Out-Null
            }
        }
        $sec = $null
        try { $sec = Invoke-SecurityResearcherTick -BatonHome $BatonHome -WriteState } catch { }
        $out = [ordered]@{
            seed     = $seed
            status   = Get-DarkFactoryStatus -BatonHome $BatonHome
            security = $sec
        }
    }
    default {
        $out = Invoke-DarkFactorySeed -BatonHome $BatonHome -Admit:($Admit -or $Action -eq 'seed') -DryRun:$DryRun
    }
}

if ($Json) { $out | ConvertTo-Json -Depth 8 } else {
    switch ($Action) {
        'status' {
            Write-Host "jobs: $($out.jobs_total)  dark-factory: $(@($out.dark_factory).Count)  security-due: $($out.security_count)"
            if ($out.curriculum.root) {
                Write-Host "grimdex-edu: shipped=$($out.curriculum.shipped) pending=$($out.curriculum.pending)"
            }
        }
        'night' {
            Write-Host "dark-factory night: seeded $(@($out.seed.created).Count)  skipped $(@($out.seed.skipped).Count)"
        }
        default {
            Write-Host "seeded: $(@($out.created).Count)  skipped: $(@($out.skipped).Count)"
            foreach ($row in @($out.created)) { Write-Host "  $($row.lane) -> $($row.job_id)" }
        }
    }
}
exit 0
