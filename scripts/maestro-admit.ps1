#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Admit queued Maestro jobs: queued → admitted | waiting-quota.

  Deterministic rules (front-door spec §6):
    - project known and not blocked by held/running sibling
    - at least one usable instrument
    - global parallel cap respected
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [int]$MaxParallel = 8,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')
. (Join-Path $PSScriptRoot 'officers-lib.ps1')
Import-MaestroEnv | Out-Null

$jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
if (-not (Test-Path -LiteralPath $jobsDir)) {
    if ($Json) { @{ admitted = @(); waiting = @(); skipped = 0 } | ConvertTo-Json }
    exit 0
}

$records = @(Get-MaestroJobRecords -JobsDir $jobsDir)
$blocks = Get-MaestroProjectBlocks -JobRecords $records
$runningCount = @($records | Where-Object { Test-MaestroJobConsumesParallelSlot -Job $_.Job }).Count
$admittedCount = @($records | Where-Object { [string]$_.Job.status -eq 'admitted' }).Count
$slots = [Math]::Max(0, $MaxParallel - $runningCount - $admittedCount)

$usable = @(Get-MaestroUsableInstruments -BatonHome $BatonHome)
$hasInstrument = $usable.Count -gt 0

# Scheduler re-evaluates queued + waiting-quota + excess_capacity. It never admits;
# Maestro still makes the admit decision after eligibility.
$queued = @($records | Where-Object {
    [string]$_.Job.status -in @('queued', 'waiting-quota', 'excess_capacity')
} | Sort-Object Created)
$admitted = @()
$waiting = @()

foreach ($rec in $queued) {
    $job = $rec.Job
    $proj = [string]$job.project

    $elig = $null
    try {
        $elig = Get-SchedulerEligibility -Job $job -BatonHome $BatonHome
    } catch { $elig = $null }
    if ($null -ne $elig -and -not [bool]$elig.eligible) {
        $st = [string]$elig.state
        if ([string]$job.status -ne $st) {
            $job.status = $st
            $job | Add-Member -NotePropertyName status_line -NotePropertyValue ([string]$elig.reason) -Force
            if ($elig.hint) {
                $job | Add-Member -NotePropertyName scheduler_hint -NotePropertyValue ([string]$elig.hint) -Force
            }
            $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rec.Path -Encoding utf8NoBOM
            Write-MaestroEvent -Root $jobsDir -JobId ([string]$job.id) -Kind 'scheduler' -Status $st
        }
        $waiting += [string]$job.id
        continue
    }

    if (-not (Test-MaestroProjectAdmittable -Project $proj -Blocks $blocks)) { continue }
    if ($slots -lt 1) { break }

    if (-not $hasInstrument) {
        $job.status = 'waiting-quota'
        $job.status_line = 'no usable instrument — retry at next window'
        $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rec.Path -Encoding utf8NoBOM
        Write-MaestroEvent -Root $jobsDir -JobId ([string]$job.id) -Kind 'waiting-quota' -Status 'waiting-quota'
        $waiting += [string]$job.id
        continue
    }

    $job.status = 'admitted'
    if ($job.PSObject.Properties['status_line']) { $job.PSObject.Properties.Remove('status_line') }
    if ($job.PSObject.Properties['scheduler_hint']) { $job.PSObject.Properties.Remove('scheduler_hint') }
    $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rec.Path -Encoding utf8NoBOM
    Write-MaestroEvent -Root $jobsDir -JobId ([string]$job.id) -Kind 'admitted' -Status 'admitted'
    $admitted += [string]$job.id
    [void]$blocks.Running.Add($proj)
    $slots--
}

if ($Json) {
    @{
        admitted = $admitted
        waiting  = $waiting
        usable   = $usable
        slots    = $slots
    } | ConvertTo-Json -Depth 4
} else {
    foreach ($id in $admitted) { Write-Host "maestro-admit: $id -> admitted" }
    foreach ($id in $waiting) { Write-Host "maestro-admit: $id -> waiting-quota" }
}

exit 0
