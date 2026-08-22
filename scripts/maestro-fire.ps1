#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fire admitted Maestro jobs via fleet-go — parallel fan-out across disjoint projects.
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [string]$FleetGo = '/Users/kev/Dev/Baton/scripts/fleet-go.ps1',
    [string]$DefaultRepo = '/Users/kev/Dev/Baton',
    [string]$FleetPath = $(Join-Path $HOME '.baton/overnight/fleet.yaml'),
    [int]$MaxParallel = 8
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')

$jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
if (-not (Test-Path -LiteralPath $jobsDir)) {
    Write-Verbose "No jobs dir: $jobsDir"
    exit 0
}

$records = @(Get-MaestroJobRecords -JobsDir $jobsDir)
$runningProjects = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($rec in @($records)) {
    if ([string]$rec.Job.status -eq 'running') {
        $p = [string]$rec.Job.project
        if ($p) { [void]$runningProjects.Add($p) }
    }
}

$runningCount = $runningProjects.Count
$slots = [Math]::Max(0, $MaxParallel - $runningCount)
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
    $jobs = foreach ($pick in $toFire) {
        Start-Job -ScriptBlock {
            param($PickPath, $PickJobJson, $JobsDir, $BatonHome, $FleetGo, $DefaultRepo, $FleetPath, $LibPath)
            . $LibPath
            $pickObj = [pscustomobject]@{
                Path = $PickPath
                Job  = ($PickJobJson | ConvertFrom-Json)
            }
            Invoke-MaestroFireOne -Pick $pickObj -JobsDir $JobsDir -BatonHome $BatonHome `
                -FleetGo $FleetGo -DefaultRepo $DefaultRepo -FleetPath $FleetPath
        } -ArgumentList (
            $pick.Path,
            ($pick.Job | ConvertTo-Json -Depth 10 -Compress),
            $jobsDir,
            $BatonHome,
            $FleetGo,
            $DefaultRepo,
            $FleetPath,
            $libPath
        )
    }
    $results = @($jobs | Wait-Job | Receive-Job)
    $jobs | Remove-Job -Force
}

$worst = 0
foreach ($r in $results) {
    Write-Host ("maestro-fire: {0} -> {1} run_id={2} provider={3}" -f $r.id, $r.status, $r.run_id, $r.provider)
    if ($r.exit -ne 0) { $worst = $r.exit }
}
exit $worst
