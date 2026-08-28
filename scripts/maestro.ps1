#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Maestro harness — bare `maestro` prints passive status; admit/status for factory actions.

.DESCRIPTION
  Bare `maestro` (or `start`) prints 3-line passive status (project, quota, jobs) and exits 0.
  `admit` queues a dark-factory job (project from cwd unless --project).
  `status` lists Maestro jobs; `go` remains the legacy natural-language admit path.
  `quota` delegates to cursor-quota.ps1 when invoked via `baton quota`.

  Power leftovers: install, fire, --json seat dump. No interactive room or stdin loop.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Subcommand = '',
    [string]$Project,
    [string]$Goal,
    [Alias('goal-file')][string]$GoalFile,
    [string]$Provider,
    [Alias('max-tier')][ValidateSet('local', 'free', 'paid')][string]$MaxCostTier = 'free',
    [Alias('bin-dir')][string]$BinDir,
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
    [switch]$Json,
    [switch]$Fire,
    [Alias('no-watch')][switch]$NoWatch
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')
Import-MaestroEnv | Out-Null

function Show-MaestroHelp {
    Write-Output 'Baton is the front door. Type:  baton'
    Write-Output 'Then say a project and what to do. ↑↓ then enter runs a line. quit leaves.'
}

function Get-BatonRepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:BATON_REPO_ROOT)) {
        return $env:BATON_REPO_ROOT
    }
    return (Split-Path $PSScriptRoot -Parent)
}

function Install-BatonCli {
    param(
        [string]$TargetBinDir,
        [string]$RepoRoot
    )
    $dir = if ($TargetBinDir) { $TargetBinDir } else { Join-Path $HOME '.local/bin' }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $dest = Join-Path $dir 'baton'
    $lines = @(
        '#!/bin/sh'
        'set -eu'
        "export BATON_REPO_ROOT=""$RepoRoot"""
        'exec pwsh -NoProfile -File "$BATON_REPO_ROOT/scripts/baton.ps1" "$@"'
    )
    Set-Content -LiteralPath $dest -Value ($lines -join "`n") -Encoding utf8NoBOM
    if (-not $IsWindows) {
        & chmod +x $dest
    }
    return $dest
}

function Start-MaestroWatchIfNeeded {
    $watch = Join-Path $HOME '.baton/overnight/bin/maestro-watch.sh'
    if (-not (Test-Path -LiteralPath $watch)) {
        return 'missing'
    }
    $pidFile = Join-Path $BatonHome 'maestro/watch.pid'
    $pidDir = Split-Path $pidFile -Parent
    if (-not (Test-Path -LiteralPath $pidDir)) {
        New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
    }
    if (Test-Path -LiteralPath $pidFile) {
        $old = [string](Get-Content -LiteralPath $pidFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($old -match '^\d+$') {
            try {
                $proc = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
                if ($proc) { return 'already' }
            } catch { }
        }
    }
    $log = Join-Path $HOME '.baton/overnight/lanes/maestro-watch.log'
    $err = Join-Path $HOME '.baton/overnight/lanes/maestro-watch.err'
    try {
        $p = Start-Process -FilePath '/bin/bash' -ArgumentList @($watch) -PassThru `
            -RedirectStandardOutput $log -RedirectStandardError $err
        [string]$p.Id | Set-Content -LiteralPath $pidFile -Encoding utf8NoBOM
        return 'started'
    } catch {
        return 'failed'
    }
}

function Test-MaestroHermeticHome {
    $real = Join-Path $HOME '.baton'
    return ($BatonHome -and ($BatonHome -ne $real))
}

function Write-BatonSeatJson {
    $seat = Get-MaestroConductorSeat -Provider $Provider
    [ordered]@{
        ok        = $true
        provider  = [string]$seat.Name
        cost_tier = [string]$seat.CostTier
        ready     = [bool]$seat.Ready
    } | ConvertTo-Json -Depth 4
}

function Invoke-BatonPassiveStatus {
    $lines = Format-BatonPassiveStatus -BatonHome $BatonHome
    foreach ($ln in $lines) { Write-Output $ln }
    [Console]::Error.WriteLine('hint     baton admit "…" · baton status · baton quota · baton --help')
}

function Invoke-MaestroAdmit {
    $text = $Goal
    if ([string]::IsNullOrWhiteSpace($text) -and $GoalFile) {
        if (-not (Test-Path -LiteralPath $GoalFile)) { throw "goal file not found: $GoalFile" }
        $text = Get-Content -LiteralPath $GoalFile -Raw
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        [Console]::Error.WriteLine('admit requires a goal: baton admit "refactor tests"')
        exit 2
    }
    $proj = $Project
    if ([string]::IsNullOrWhiteSpace($proj)) {
        $ctx = Resolve-BatonProjectFromCwd -BatonHome $BatonHome
        if (-not $ctx.Registered) {
            [Console]::Error.WriteLine('admit: cwd is not a registered project. Use --project <id>.')
            exit 2
        }
        $proj = [string]$ctx.Id
    }
    $seat = Get-MaestroConductorSeat -Provider $Provider
    $job = New-MaestroJob -BatonHome $BatonHome -Project $proj -Goal $text.Trim() `
        -MaxCostTier $MaxCostTier -Source 'cli' -Provider $seat.Name
    if ($Fire) {
        $fireScript = Join-Path $PSScriptRoot 'maestro-fire.ps1'
        & pwsh -NoProfile -File $fireScript -BatonHome $BatonHome | Out-Null
        $jobPath = Join-Path (Get-MaestroJobsDir -BatonHome $BatonHome) "$($job.id).json"
        if (Test-Path -LiteralPath $jobPath) {
            $job = Get-Content -LiteralPath $jobPath -Raw | ConvertFrom-Json
        }
    }
    if ($Json) { $job | ConvertTo-Json -Depth 6; return }
    Write-Output ("admitted {0} — {1}" -f $job.id, $job.goal)
}

function Invoke-MaestroGo {
    if ([string]::IsNullOrWhiteSpace($Project)) {
        throw 'go requires --project <registry-id>'
    }
    $text = $Goal
    if ([string]::IsNullOrWhiteSpace($text) -and $GoalFile) {
        if (-not (Test-Path -LiteralPath $GoalFile)) { throw "goal file not found: $GoalFile" }
        $text = Get-Content -LiteralPath $GoalFile -Raw
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'go requires --goal "..." or --goal-file'
    }
    $seat = Get-MaestroConductorSeat -Provider $Provider
    $job = New-MaestroJob -BatonHome $BatonHome -Project $Project -Goal $text `
        -MaxCostTier $MaxCostTier -Source 'cli' -Provider $seat.Name
    $fired = $null
    if ($Fire) {
        $fireScript = Join-Path $PSScriptRoot 'maestro-fire.ps1'
        & pwsh -NoProfile -File $fireScript -BatonHome $BatonHome | Out-Null
        $jobPath = Join-Path (Get-MaestroJobsDir -BatonHome $BatonHome) "$($job.id).json"
        if (Test-Path -LiteralPath $jobPath) {
            $fired = Get-Content -LiteralPath $jobPath -Raw | ConvertFrom-Json
        }
    }
    $out = $job
    if ($fired) { $out = $fired }
    if ($Json) {
        $out | ConvertTo-Json -Depth 6
        return
    }
    Write-Output ("maestro: {0} {1} project={2} max_tier={3} seat={4}" -f `
        $out.status, $out.id, $out.project, $out.max_cost_tier, $seat.Name)
}

function Invoke-MaestroStatus {
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    $jobs = @()
    if (Test-Path -LiteralPath $jobsDir) {
        $jobs = @(Get-MaestroJobRecords -JobsDir $jobsDir | ForEach-Object { $_.Job } | Sort-Object created_at -Descending)
    }
    if ($Json) {
        @{ jobs = @($jobs) } | ConvertTo-Json -Depth 8
        return
    }
    if ($jobs.Count -eq 0) {
        Write-Output 'maestro: no jobs'
        return
    }
    foreach ($j in $jobs) {
        Write-Output ("{0,-16} {1,-18} {2,-14} {3}" -f $j.id, $j.project, $j.status, $j.goal)
    }
}

function Invoke-MaestroInstall {
    $repo = Get-BatonRepoRoot
    $path = Install-BatonCli -TargetBinDir $BinDir -RepoRoot $repo
    if ($Json) {
        [ordered]@{ ok = $true; path = $path; repo = $repo } | ConvertTo-Json
        return
    }
    Write-Output ("Installed baton -> {0}" -f $path)
    Write-Output ("BATON_REPO_ROOT={0}" -f $repo)
    Write-Output 'Next: baton'
}

$cmd = $Subcommand.Trim().ToLowerInvariant()

if ($cmd -eq 'admit' -and [string]::IsNullOrWhiteSpace($Goal) -and $args.Count -gt 0) {
    $Goal = ($args -join ' ').Trim()
}

switch ($cmd) {
    { $_ -in @('help', '--help', '-h') } { Show-MaestroHelp; exit 0 }
    'go' { Invoke-MaestroGo; exit 0 }
    'admit' { Invoke-MaestroAdmit; exit 0 }
    'status' { Invoke-MaestroStatus; exit 0 }
    'install' { Invoke-MaestroInstall; exit 0 }
    { $_ -in @('', 'start') } {
        if ($Json) { Write-BatonSeatJson; exit 0 }
        Invoke-BatonPassiveStatus
        exit 0
    }
    'fire' {
        $fireScript = Join-Path $PSScriptRoot 'maestro-fire.ps1'
        & pwsh -NoProfile -File $fireScript -BatonHome $BatonHome
        exit $LASTEXITCODE
    }
    default {
        [Console]::Error.WriteLine("maestro: unknown subcommand '$Subcommand'")
        Show-MaestroHelp
        exit 2
    }
}
