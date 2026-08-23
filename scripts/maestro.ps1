#!/usr/bin/env pwsh
<#
.SYNOPSIS
  The Baton room — you type `baton`, you are in Maestro.

.DESCRIPTION
  Bare `baton` starts this. Say a project and what to do in plain English.
  Type status for this project. Type quit to leave.

  Power leftovers (not the front door): install, fire, --json seat dump.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Subcommand = '',
    [string]$Project,
    [string]$Goal,
    [Alias('goal-file')][string]$GoalFile,
    [string]$Provider,
    [Alias('max-tier')][ValidateSet('local', 'free', 'paid')][string]$MaxCostTier = 'paid',
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

function Get-BatonRoomCardText {
    param($Room)
    return (Format-MaestroRoomBanner -SeatName $Room.SeatName -Choices $Room.Choices -CurrentProject $Room.Current -LastList $Room.LastList -ScrollIndex $Room.ScrollIndex)
}

function Read-BatonRoomLine {
    param(
        $Items,
        $Room
    )
    if ([Console]::IsInputRedirected) {
        return [Console]::In.ReadLine()
    }
    $arr = @($Items)
    $buf = ''
    $prefix = (Get-MaestroAnsi cyan) + 'baton › ' + (Get-MaestroAnsi reset)
    $page = 8
    $inputRows = 1
    Write-Host -NoNewline $prefix
    while ($true) {
        try {
            $k = [Console]::ReadKey($true)
        } catch {
            return [Console]::In.ReadLine()
        }
        if ($k.Key -eq 'Enter') {
            Write-Host ''
            if ([string]::IsNullOrWhiteSpace($buf) -and $arr.Count -gt 0) {
                return [string]$arr[$Room.ScrollIndex].Run
            }
            return $buf
        }
        $moved = $false
        if ($k.Key -eq 'Escape') {
            $buf = ''
        } elseif ($k.Key -eq [ConsoleKey]::UpArrow -and $arr.Count -gt 0) {
            $Room.ScrollIndex = Move-MaestroScrollIndex -Count $arr.Count -Index $Room.ScrollIndex -Delta -1
            $moved = $true
        } elseif ($k.Key -eq [ConsoleKey]::DownArrow -and $arr.Count -gt 0) {
            $Room.ScrollIndex = Move-MaestroScrollIndex -Count $arr.Count -Index $Room.ScrollIndex -Delta 1
            $moved = $true
        } elseif ($k.Key -eq [ConsoleKey]::PageUp -and $arr.Count -gt 0) {
            $Room.ScrollIndex = Move-MaestroScrollIndex -Count $arr.Count -Index $Room.ScrollIndex -Delta (-$page)
            $moved = $true
        } elseif ($k.Key -eq [ConsoleKey]::PageDown -and $arr.Count -gt 0) {
            $Room.ScrollIndex = Move-MaestroScrollIndex -Count $arr.Count -Index $Room.ScrollIndex -Delta $page
            $moved = $true
        } elseif ($k.Key -eq [ConsoleKey]::Home -and $arr.Count -gt 0) {
            $Room.ScrollIndex = 0
            $moved = $true
        } elseif ($k.Key -eq [ConsoleKey]::End -and $arr.Count -gt 0) {
            $Room.ScrollIndex = $arr.Count - 1
            $moved = $true
        } elseif ($k.Key -eq 'Backspace') {
            if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1) }
        } elseif ($k.KeyChar -and [int][char]$k.KeyChar -ge 32) {
            $buf += $k.KeyChar
        }
        if ($moved) {
            $card = Get-BatonRoomCardText -Room $Room
            $paint = Format-MaestroRoomRedraw -Banner $card -PreviousLineCount ([int]$Room.BannerLines)
            [Console]::Write($paint)
            $Room.BannerLines = Get-MaestroRoomPaintHeight -Text $card
            $inputRows = 1
        }
        $redraw = Format-MaestroInputRedraw -Prefix $prefix -Buffer $buf -PreviousRowCount $inputRows
        [Console]::Write([string]$redraw.Text)
        $inputRows = [int]$redraw.Rows
    }
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

function Invoke-BatonRoom {
    $seat = Get-MaestroConductorSeat -Provider $Provider
    if (-not $NoWatch -and -not (Test-MaestroHermeticHome)) {
        [void](Start-MaestroWatchIfNeeded)
    }
    $choices = @(Get-MaestroRoomChoices -BatonHome $BatonHome)
    $visible = @($choices)
    $room = @{
        SeatName    = $seat.Name
        Choices     = $choices
        Current     = $null
        LastList    = ''
        ScrollIndex = 0
        BannerLines = 0
    }
    function Get-BatonScrollItemsNow {
        return @(Get-MaestroRoomScrollItems -Choices $choices -CurrentProject $room.Current -Mode 'all')
    }
    function Set-BatonCurrentProject {
        param($Pick)
        $room.Current = Resolve-MaestroRoomCurrent -Pick $Pick -Choices $choices
        $room.LastList = ''
        $room.ScrollIndex = Find-MaestroScrollIndex -Items (Get-BatonScrollItemsNow) -Run $room.Current
        Write-Output ("Working on {0}." -f $room.Current)
    }
    function Write-BatonRoomCard {
        $card = Get-BatonRoomCardText -Room $room
        $room.BannerLines = Get-MaestroRoomPaintHeight -Text $card
        Write-Output $card
    }
    Write-BatonRoomCard
    function Show-BatonInputChrome {
        $items = Get-BatonScrollItemsNow
        if ($items.Count -eq 0) {
            $room.ScrollIndex = 0
        } elseif ($room.ScrollIndex -ge $items.Count) {
            $room.ScrollIndex = 0
        }
        Write-Output ''
        Write-BatonRoomCard
    }
    while ($true) {
        $scrollItems = Get-BatonScrollItemsNow
        if ([Console]::IsInputRedirected) {
            Write-Output 'baton ›'
        }
        $line = Read-BatonRoomLine -Items $scrollItems -Room $room
        if ($null -eq $line) { break }
        $line = $line.Trim()
        if ($line -eq '') {
            Show-BatonInputChrome
            continue
        }
        if ($line -match '^(quit|exit|q)$') { break }
        if ($line -match '^(help|\?)$') {
            Write-Output (Format-MaestroRoomKeywords)
            Write-BatonRoomCard
            continue
        }
        if ($line -eq 'jobs') {
            $room.LastList = ''
            Invoke-MaestroStatus
            continue
        }
        if ($line -eq 'status') {
            $st = Get-MaestroProjectStatus -BatonHome $BatonHome -Project $room.Current -Choices $choices
            Write-Output $st.Text
            $visible = @($st.Worktrees)
            $room.LastList = if ($visible.Count -gt 0) { 'worktrees' } else { '' }
            continue
        }
        if ($line -eq 'quota') {
            $room.LastList = ''
            . (Join-Path $PSScriptRoot 'cursor-quota-lib.ps1')
            Write-Output (Format-BatonQuotaPanel -BatonHome $BatonHome)
            continue
        }
        if ($line -in @('projects', 'worktrees')) {
            if ($choices.Count -eq 0) {
                $choices = @(Get-MaestroRoomChoices -BatonHome $BatonHome)
                $room.Choices = $choices
            }
            if ($line -eq 'projects') {
                $visible = @($choices | Where-Object { $_.Kind -eq 'project' })
                $empty = 'No projects found.'
            } else {
                $visible = @($choices)
                $empty = 'No projects or worktrees found.'
            }
            $room.LastList = $line
            $room.ScrollIndex = 0
            if ($visible.Count -eq 0) {
                Write-Output $empty
                Show-BatonInputChrome
                continue
            }
            $i = 1
            foreach ($c in $visible) {
                Write-Output ("  {0,2}  {1,-22} {2}" -f $i, $c.Label, $c.Kind)
                $i++
            }
            Write-Output 'Type a number to pick one.'
            continue
        }
        if ($line -match '^\d+$') {
            $n = [int]$line
            if ($n -lt 1 -or $n -gt $visible.Count) {
                Write-Output 'Not on the list. Type projects or status.'
                Show-BatonInputChrome
                continue
            }
            Set-BatonCurrentProject -Pick $visible[$n - 1]
            Show-BatonInputChrome
            continue
        }
        $named = Find-MaestroRoomExactPick -Choices $choices -Text $line
        if ($named) {
            Set-BatonCurrentProject -Pick $named
            Show-BatonInputChrome
            continue
        }
        $parsed = Resolve-MaestroUtterance -Text $line -Choices $choices -CurrentProject $room.Current
        if (-not $parsed.Project) {
            Write-Output 'Say which project, or type projects and pick a number.'
            Show-BatonInputChrome
            continue
        }
        $room.Current = [string]$parsed.Project
        $room.LastList = ''
        $room.ScrollIndex = 0
        $job = New-MaestroJob -BatonHome $BatonHome -Project $room.Current -Goal $parsed.Goal `
            -MaxCostTier $MaxCostTier -Source 'cli' -Provider $seat.Name
        Write-Output ("Queued {0} ({1}) on {2}." -f $job.id, $job.status, $job.project)
        Write-Output ("Goal: {0}" -f $job.goal)
        Write-Output 'Maestro watch will admit and fire when a slot opens. Type jobs for the queue, status for worktrees.'
        Show-BatonInputChrome
    }
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
        $stat = [string]$j.status
        $outcome = Get-MaestroRunOutcome -BatonHome $BatonHome -RunId ([string]$j.run_id)
        if ($outcome) { $stat = '{0}/{1}' -f $stat, $outcome }
        Write-Output ("{0,-16} {1,-18} {2,-14} {3}" -f $j.id, $j.project, $stat, $j.goal)
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

switch ($cmd) {
    { $_ -in @('help', '--help', '-h') } { Show-MaestroHelp; exit 0 }
    'go' { Invoke-MaestroGo; exit 0 }
    'status' { Invoke-MaestroStatus; exit 0 }
    'install' { Invoke-MaestroInstall; exit 0 }
    { $_ -in @('', 'start') } {
        if ($Json) { Write-BatonSeatJson; exit 0 }
        Invoke-BatonRoom
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
