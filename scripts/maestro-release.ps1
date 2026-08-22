#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Release a held Maestro job back to its prior status (usually queued or admitted).

  Mirrors POST /maestro/jobs/<id>/release and dashboard.readers.maestro_jobs.release_job.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JobId,
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')

$jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
try {
    $job = Invoke-MaestroReleaseJob -JobsDir $jobsDir -JobId $JobId
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if ($Json) {
    $job | ConvertTo-Json -Depth 10
} else {
    Write-Host "maestro-release: $JobId -> $($job.status)"
}

exit 0
