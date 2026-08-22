#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fire admitted Maestro jobs via fleet-go — parallel fan-out across disjoint projects.

.NOTES
  Jobs live at $BATON_HOME/maestro/jobs/*.json. Invokes the box-local fleet-go runner;
  does not merge branches or touch master.
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [string]$FleetGo = $(Join-Path $PSScriptRoot 'fleet-go.ps1'),
    [string]$DefaultRepo = $(Split-Path $PSScriptRoot -Parent),
    [string]$FleetPath = '',
    [int]$MaxParallel = 8
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')
Import-MaestroEnv | Out-Null

if ([string]::IsNullOrWhiteSpace($FleetPath)) {
    $FleetPath = Join-Path $BatonHome 'overnight/fleet.yaml'
}

$jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
if (-not (Test-Path -LiteralPath $jobsDir)) {
    Write-Verbose "No jobs dir: $jobsDir"
    exit 0
}

$records = @(Get-MaestroJobRecords -JobsDir $jobsDir)
$runningProjects = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$runningSlots = 0
foreach ($rec in @($records)) {
    if (-not (Test-MaestroJobConsumesParallelSlot -Job $rec.Job)) { continue }
    $runningSlots++
    $p = [string]$rec.Job.project
    if ($p) { [void]$runningProjects.Add($p) }
}

$slots = [Math]::Max(0, $MaxParallel - $runningSlots)
if ($slots -lt 1) {
    Write-Verbose 'Parallel cap reached — skip fire tick.'
    exit 0
}

$admitted = @($records | Where-Object {
    [string]$_.Job.status -eq 'admitted' -and
    -not $runningProjects.Contains([string]$_.Job.project)
} | Sort-Object Created)

if ($admitted.Count -lt 1) {
    Write-Verbose 'No admitted jobs.'
    exit 0
}

$toFire = @()
$claimed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($rec in $admitted) {
    $proj = [string]$rec.Job.project
    if ($claimed.Contains($proj)) { continue }
    $toFire += $rec
    [void]$claimed.Add($proj)
    if ($toFire.Count -ge $slots) { break }
}

$libPath = Join-Path $PSScriptRoot 'maestro-lib.ps1'
$results = @()

if ($toFire.Count -eq 1) {
    $results += Invoke-MaestroFireOne -Pick $toFire[0] -JobsDir $jobsDir -BatonHome $BatonHome `
        -FleetGo $FleetGo -DefaultRepo $DefaultRepo -FleetPath $FleetPath
} else {
    $results = @($toFire | ForEach-Object -Parallel {
        . $using:libPath
        Import-MaestroEnv | Out-Null
        Invoke-MaestroFireOne -Pick $_ -JobsDir $using:jobsDir -BatonHome $using:BatonHome `
            -FleetGo $using:FleetGo -DefaultRepo $using:DefaultRepo -FleetPath $using:FleetPath
    } -ThrottleLimit $MaxParallel)
}

$worst = 0
foreach ($r in $results) {
    Write-Host ("maestro-fire: {0} -> {1} run_id={2} provider={3}" -f $r.id, $r.status, $r.run_id, $r.provider)
    if ($r.exit -ne 0) { $worst = $r.exit }
}
exit $worst
