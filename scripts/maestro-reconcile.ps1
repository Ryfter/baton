#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Reconcile Maestro job board: requeue recoverable waiting-quota, fold stale goals.
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')
Import-MaestroEnv | Out-Null

$jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
if (-not (Test-Path -LiteralPath $jobsDir)) {
    if ($Json) { @{ requeued = @(); folded = @() } | ConvertTo-Json }
    exit 0
}

$usable = @(Get-MaestroUsableInstruments -BatonHome $BatonHome)
$hasInstrument = $usable.Count -gt 0
$requeued = @()
$folded = @()

$foldPatterns = @(
    @{ match = 'Maestro slice 3'; note = 'slice 3 shipped — folded by reconcile' },
    @{ match = 'kevin-decision.md A/B/C'; note = 'BookProfile C stamped — folded by reconcile' },
    @{ match = 'host cards \(mini,5090,Pi,edge\)'; note = 'Grimlore env cards shipped — folded by reconcile' },
    @{ match = 'Boss wave 8'; note = 'TD boss wave shipped — folded by reconcile' },
    @{ match = 'POST /ask 500'; note = 'AnswerBot /ask fixed — folded by reconcile' },
    @{ match = 'shell-edit-doctor'; note = 'canvas install.sh shipped — folded by reconcile' },
    @{ match = 'toc_scheduler tests'; note = 'bench-gauntlet ToC tests shipped — folded by reconcile' }
)

foreach ($f in Get-ChildItem -LiteralPath $jobsDir -Filter 'mj-*.json' -File) {
    try {
        $job = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
    } catch { continue }

    $st = [string]$job.status
    $goal = [string]$job.goal
    $id = [string]$job.id

    if ($st -eq 'waiting-quota' -and $hasInstrument) {
        Set-MaestroJobStatus -Job $job -Status 'queued' -StatusLine 'requeued by maestro-reconcile'
        $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $f.FullName -Encoding utf8NoBOM
        Write-MaestroEvent -Root $jobsDir -JobId $id -Kind 'requeue' -Status 'queued'
        $requeued += $id
        continue
    }

    if ($st -in @('queued', 'admitted', 'waiting-quota', 'running') -and $goal) {
        foreach ($pat in $foldPatterns) {
            if ($goal -match $pat.match) {
                if ($st -eq 'running' -and (Test-MaestroJobConsumesParallelSlot -Job $job)) {
                    break
                }
                Set-MaestroJobStatus -Job $job -Status 'done' -StatusLine $pat.note
                $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $f.FullName -Encoding utf8NoBOM
                Write-MaestroEvent -Root $jobsDir -JobId $id -Kind 'fold' -Status 'done'
                $folded += $id
                break
            }
        }
    }
}

if ($Json) {
    @{ requeued = $requeued; folded = $folded; usable = $usable } | ConvertTo-Json -Depth 4
} else {
    foreach ($id in $requeued) { Write-Host "maestro-reconcile: $id -> queued" }
    foreach ($id in $folded) { Write-Host "maestro-reconcile: $id -> done (stale)" }
}

exit 0
