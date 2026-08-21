#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Admit one Maestro job: oldest status=admitted → running → fleet-go → patch job JSON.

.NOTES
  Jobs live at $BATON_HOME/maestro/jobs/*.json. Invokes the box-local fleet-go runner;
  does not merge branches or touch master.
#>
[CmdletBinding()]
param(
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [string]$FleetGo = $(Join-Path $PSScriptRoot 'fleet-go.ps1'),
    [string]$DefaultRepo = $(Split-Path $PSScriptRoot -Parent),
    [string]$FleetPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')

if ([string]::IsNullOrWhiteSpace($FleetPath)) {
    $FleetPath = Join-Path $BatonHome 'overnight/fleet.yaml'
}

$jobsDir = Join-Path $BatonHome 'maestro/jobs'
if (-not (Test-Path -LiteralPath $jobsDir)) {
    Write-Verbose "No jobs dir: $jobsDir"
    exit 0
}

$admitted = @(Get-ChildItem -LiteralPath $jobsDir -Filter 'mj-*.json' -File | ForEach-Object {
    try {
        $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        if ([string]$j.status -eq 'admitted') {
            [pscustomobject]@{ Path = $_.FullName; Job = $j; Created = [string]$j.created_at }
        }
    } catch { }
} | Sort-Object Created)

if ($admitted.Count -lt 1) {
    Write-Verbose 'No admitted jobs.'
    exit 0
}

$pick = $admitted[0]
$job = $pick.Job
$jobPath = $pick.Path

if ([string]$job.status -ne 'admitted') { exit 0 }

$job.status = 'running'
$job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jobPath -Encoding utf8NoBOM
Write-MaestroEvent -Root $jobsDir -JobId ([string]$job.id) -Kind 'firing'

$repoPath = Resolve-MaestroRepoPath -BatonHome $BatonHome -ProjectId ([string]$job.project) -DefaultRepo $DefaultRepo
$stakes = if ($job.stakes) { [string]$job.stakes } else { 'standard' }

$goArgs = @{
    Goal       = [string]$job.goal
    RepoPath   = $repoPath
    FleetPath  = $FleetPath
    Execute    = $true
    NoPlanGate = $true
    NoVerify   = $true
    Stakes     = $stakes
    Json       = $true
}

$raw = ''
$exit = 0
try {
    $raw = (& pwsh -NoProfile -File $FleetGo @goArgs | Out-String).Trim()
    $exit = $LASTEXITCODE
} catch {
    $raw = $_.Exception.Message
    $exit = 1
}

$patch = @{
    run_id   = $null
    provider = $null
    status   = 'done'
}

if ($raw) {
    try {
        $out = $raw | ConvertFrom-Json
        if ($out.run_id) { $patch.run_id = [string]$out.run_id }
        $prov = Get-GoProvider -Out $out
        if ($prov) { $patch.provider = $prov }
        $patch.status = Resolve-MaestroStatusFromGo -GoStatus ([string]$out.status) -GoWhy ([string]$out.report)
    } catch {
        if ($exit -ne 0 -and ($raw -match 'quota|rate.?limit|labor-unavailable|no candidate')) {
            $patch.status = 'waiting-quota'
        }
    }
} elseif ($exit -ne 0) {
    $patch.status = 'waiting-quota'
}

Update-MaestroJobFile -Path $jobPath -Patch $patch
Write-MaestroEvent -Root $jobsDir -JobId ([string]$job.id) -Kind 'fired' -Status $patch.status -RunId $patch.run_id -Provider $patch.provider
Write-Host ("maestro-fire: {0} -> {1} run_id={2} provider={3}" -f $job.id, $patch.status, $patch.run_id, $patch.provider)
exit $exit
