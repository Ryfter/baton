#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fold stale running Maestro jobs (placeholders, old orch, aged running).
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [int]$MaxRunningHours = 4,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')

$jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
$folded = @()
if (-not (Test-Path -LiteralPath $jobsDir)) {
    if ($Json) { @{ folded = @() } | ConvertTo-Json }; exit 0
}

$cutoff = (Get-Date).AddHours(-1 * $MaxRunningHours)

foreach ($f in Get-ChildItem -LiteralPath $jobsDir -Filter 'mj-*.json' -File) {
    try { $job = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ([string]$job.status -ne 'running') { continue }

    $id = [string]$job.id
    $src = [string]$job.source
    $goal = [string]$job.goal
    $reason = $null

    if ($src -eq 'ensure-conductors') {
        $reason = 'conductor placeholder complete — folded by maestro-fold-stale'
    }
    elseif ($goal -match 'Orchestrator.*(complete|shipped|folded)' -or $goal -match 'Maestro slice [1-5]:') {
        $reason = 'stale orchestrator goal — folded by maestro-fold-stale'
    }
    elseif ($job.updated_at) {
        try {
            $upd = [datetime]::Parse([string]$job.updated_at)
            if ($upd -lt $cutoff) { $reason = "running > ${MaxRunningHours}h — folded by maestro-fold-stale" }
        } catch { }
    }

    if (-not $reason) { continue }

    if (-not $DryRun) {
        Set-MaestroJobStatus -Job $job -Status 'done' -StatusLine $reason
        $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $f.FullName -Encoding utf8NoBOM
        Write-MaestroEvent -Root $jobsDir -JobId $id -Kind 'fold' -Status 'done'
    }
    $folded += [pscustomobject]@{ id = $id; project = [string]$job.project; reason = $reason }
}

if ($Json) { @{ folded = $folded; dry_run = [bool]$DryRun } | ConvertTo-Json -Depth 4 }
else {
    foreach ($x in $folded) { Write-Host ("maestro-fold-stale: {0} ({1}) -> done [{2}]" -f $x.id, $x.project, $x.reason) }
    if ($folded.Count -eq 0) { Write-Host 'maestro-fold-stale: nothing to fold' }
}
exit 0
