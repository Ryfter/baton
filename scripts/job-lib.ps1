#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared PowerShell library for job lifecycle. Dot-source from slash command
  scripts and the hook.

.DESCRIPTION
  Functions:
    Read-CurrentJob   — returns @{ job_id; phase } from state file
    Write-CurrentJob  — writes state file
    Clear-CurrentJob  — deletes state file
    (more added in later tasks)
#>

$script:DefaultStatePath = (Join-Path $HOME '.claude/current-job.json')

function Read-CurrentJob {
    param([string]$StatePath = $script:DefaultStatePath)
    $result = @{ job_id = $null; phase = $null }
    if (-not (Test-Path $StatePath)) { return $result }
    try {
        $raw = Get-Content $StatePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $result }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $result.job_id = $obj.job_id
        $result.phase  = $obj.phase
    } catch {
        # Corrupted or unreadable → treat as no active job.
        # Contract: this function must never throw. Bare catch is intentional;
        # surface details to debug stream for callers who set $DebugPreference.
        Write-Debug "Read-CurrentJob: $($_.Exception.Message)"
    }
    return $result
}

function Write-CurrentJob {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Phase,
        [string]$StatePath = $script:DefaultStatePath
    )
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    @{ job_id = $JobId; phase = $Phase } | ConvertTo-Json | Set-Content -Path $StatePath -Encoding utf8NoBOM
}

function Clear-CurrentJob {
    param([string]$StatePath = $script:DefaultStatePath)
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
}
