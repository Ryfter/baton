#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Dark factory Level-4 automation — seed Maestro lanes, status, curriculum hooks.
.DESCRIPTION
  Queues overnight work for dashboard, Baton spine, and Grimdex-edu curriculum build-out.
  Kevin sleeps; Maestro admit → fire → worktrees do the labor.
#>
. (Join-Path $PSScriptRoot 'baton-home.ps1')
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')
. (Join-Path $PSScriptRoot 'security-researcher-lib.ps1')

$script:DarkFactoryGrimdexEduRoot = '/Users/kev/Dev/Grimdex-edu'
$script:DarkFactoryGrimdexEduProject = 'grimdex-edu'

function Get-DarkFactoryGrimdexEduRoot {
    param([string]$BatonHome = (Get-BatonHome))
    if ($env:GRIMDEX_EDU_ROOT -and (Test-Path -LiteralPath $env:GRIMDEX_EDU_ROOT)) {
        return (Resolve-Path -LiteralPath $env:GRIMDEX_EDU_ROOT).Path
    }
    $rec = Join-Path $BatonHome "projects/$($script:DarkFactoryGrimdexEduProject)/project.json"
    if (Test-Path -LiteralPath $rec) {
        try {
            $doc = Get-Content -LiteralPath $rec -Raw | ConvertFrom-Json
            $folder = [string]$doc.folder
            if ($folder -and (Test-Path -LiteralPath $folder)) {
                return (Resolve-Path -LiteralPath $folder).Path
            }
        } catch { }
    }
    if (Test-Path -LiteralPath $script:DarkFactoryGrimdexEduRoot) {
        return (Resolve-Path -LiteralPath $script:DarkFactoryGrimdexEduRoot).Path
    }
    return $null
}

function Get-DarkFactoryLanes {
    <# Canonical overnight lanes — one queued job per track unless already active. #>
    return @(
        [ordered]@{
            lane       = 'dashboard'
            project    = 'baton'
            stakes     = 'standard'
            instrument = 'coding'
            goal       = @'
Dark factory dashboard slice: add a Dark Factory panel to the Baton dashboard (HTMX partial on home).
Show: Maestro job queue counts, security-researcher due projects, Grimdex-edu curriculum shipped vs backlog.
Add dashboard/readers/dark_factory.py, routers/dark_factory.py, partial + styles, pytest coverage.
Keep the existing maestro compose strip; this is an ops card above the fleet row.
'@
        }
        [ordered]@{
            lane       = 'baton-spine'
            project    = 'baton'
            stakes     = 'standard'
            instrument = 'coding-pwsh'
            goal       = @'
Dark factory automation wedge: scripts/dark-factory-lib.ps1 seed + status, fleet-dark-factory.ps1 CLI,
verbs.yaml entry, and dark-factory-night.sh that runs seed → maestro-admit → maestro-fire once.
Document in commands/dark-factory.md. Hermetic test-dark-factory-lib.ps1. Ox Alpha for labor.
'@
        }
        [ordered]@{
            lane       = 'grimdex-edu-curriculum'
            project    = $script:DarkFactoryGrimdexEduProject
            stakes     = 'standard'
            instrument = 'coding-pwsh'
            goal       = @'
Grimdex-edu curriculum build-out: read learn/curriculum-backlog.yaml and scripts/curriculum-audit.ps1.
Ship the highest-priority missing lesson pages (capability markdown under learn/*/capabilities/).
Each page needs: front matter, ## In plain terms, ## Official sources, pass-through links.
Run curriculum-audit.ps1 and update docs/curriculum-roadmap.md with shipped vs pending counts.
'@
        }
    )
}

function Ensure-DarkFactoryProjectRegistry {
    param([string]$BatonHome = (Get-BatonHome))
    $projDir = Join-Path $BatonHome "projects/$($script:DarkFactoryGrimdexEduProject)"
    $recPath = Join-Path $projDir 'project.json'
    if (Test-Path -LiteralPath $recPath) { return $recPath }
    $root = Get-DarkFactoryGrimdexEduRoot -BatonHome $BatonHome
    if (-not $root) { return $null }
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    $rec = [ordered]@{
        id     = $script:DarkFactoryGrimdexEduProject
        name   = 'Grimdex-edu'
        folder = $root
        agent  = 'baton'
        notes  = 'Learn module — verbose educational layer (D41). Auto-registered by dark-factory.'
    }
    ($rec | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $recPath -Encoding utf8NoBOM
    return $recPath
}

function New-DarkFactoryMaestroJob {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Goal,
        [string]$Stakes = 'standard',
        [string]$Source = 'cli',
        [string]$Status = 'queued',
        [string]$BatonHome = (Get-BatonHome)
    )
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $jobsDir)) {
        New-Item -ItemType Directory -Force -Path $jobsDir | Out-Null
    }
    $jid = 'mj-' + ([guid]::NewGuid().ToString('n').Substring(0, 12))
    $job = [ordered]@{
        id          = $jid
        project     = $Project
        goal        = $Goal.Trim()
        stakes      = $Stakes
        missed_fire = 'catch-up'
        source      = $Source
        status      = $Status
        provider    = $null
        run_id      = $null
        created_at  = ([datetime]::UtcNow).ToString('o')
        tags        = @('dark-factory')
    }
    ($job | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $jobsDir "$jid.json") -Encoding utf8NoBOM
    Write-MaestroEvent -Root $jobsDir -JobId $jid -Kind 'queued' -Status $Status
    return $job
}

function Test-DarkFactoryLaneActive {
    param(
        [Parameter(Mandatory)][string]$Lane,
        [Parameter(Mandatory)][string]$Project,
        [string]$BatonHome = (Get-BatonHome)
    )
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $jobsDir)) { return $false }
    foreach ($rec in @(Get-MaestroJobRecords -JobsDir $jobsDir)) {
        $j = $rec.Job
        if ([string]$j.project -ne $Project) { continue }
        $st = [string]$j.status
        if ($st -in @('done', 'held')) { continue }
        $goal = [string]$j.goal
        if ($goal -notmatch "<!--\s*dark-factory:lane=$([regex]::Escape($Lane))\s*-->") { continue }
        if ($st -in @('queued', 'admitted', 'running', 'waiting-quota', 'excess_capacity')) {
            return $true
        }
    }
    return $false
}

function Invoke-DarkFactorySeed {
    param(
        [string]$BatonHome = (Get-BatonHome),
        [switch]$Admit,
        [switch]$DryRun
    )
    Ensure-DarkFactoryProjectRegistry -BatonHome $BatonHome | Out-Null
    $created = [System.Collections.ArrayList]@()
    $skipped = [System.Collections.ArrayList]@()
    foreach ($lane in @(Get-DarkFactoryLanes)) {
        $proj = [string]$lane.project
        $name = [string]$lane.lane
        if (Test-DarkFactoryLaneActive -Lane $name -Project $proj -BatonHome $BatonHome) {
            [void]$skipped.Add($name)
            continue
        }
        if ($DryRun) {
            [void]$created.Add([ordered]@{ lane = $name; project = $proj; dry_run = $true })
            continue
        }
        $markedGoal = "<!-- dark-factory:lane=$name -->`n$([string]$lane.goal)"
        $job = New-DarkFactoryMaestroJob -Project $proj -Goal $markedGoal -Stakes ([string]$lane.stakes) -BatonHome $BatonHome
        [void]$created.Add([ordered]@{ lane = $name; job_id = [string]$job.id; project = $proj })
    }
    $admitted = @()
    if ($Admit -and -not $DryRun) {
        $admitScript = Join-Path $PSScriptRoot 'maestro-admit.ps1'
        if (Test-Path -LiteralPath $admitScript) {
            $admitJson = & pwsh -NoProfile -File $admitScript -BatonHome $BatonHome -Json 2>$null | ConvertFrom-Json
            $admitted = @($admitJson.admitted)
        }
    }
    return [ordered]@{
        created  = @($created)
        skipped  = @($skipped)
        admitted = $admitted
    }
}

function Get-DarkFactoryStatus {
    param([string]$BatonHome = (Get-BatonHome))
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    $jobs = @()
    if (Test-Path -LiteralPath $jobsDir) {
        $jobs = @(Get-MaestroJobRecords -JobsDir $jobsDir | ForEach-Object { $_.Job })
    }
    $byStatus = @{}
    foreach ($j in $jobs) {
        $st = [string]$j.status
        if (-not $byStatus.ContainsKey($st)) { $byStatus[$st] = 0 }
        $byStatus[$st]++
    }
    $dfJobs = @($jobs | Where-Object {
        ($_.tags -and @($_.tags) -contains 'dark-factory') -or ([string]$_.goal -match 'Dark factory|dark factory|Grimdex-edu curriculum')
    })
    $sec = $null
    try { $sec = Invoke-SecurityResearcherTick -BatonHome $BatonHome } catch { $sec = @{ count = 0; due = @() } }
    $eduRoot = Get-DarkFactoryGrimdexEduRoot -BatonHome $BatonHome
    $curriculum = @{ root = $eduRoot; shipped = 0; pending = 0; modules = @() }
    if ($eduRoot) {
        $auditScript = Join-Path $eduRoot 'scripts/curriculum-audit.ps1'
        if (Test-Path -LiteralPath $auditScript) {
            try {
                $auditJson = & pwsh -NoProfile -File $auditScript -Json 2>$null | ConvertFrom-Json
                if ($auditJson) { $curriculum = $auditJson }
            } catch { }
        } else {
            $pages = @(Get-ChildItem -LiteralPath (Join-Path $eduRoot 'learn') -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '[\\/]capabilities[\\/]' })
            $curriculum.shipped = $pages.Count
        }
    }
    return [ordered]@{
        schema_version = 1
        jobs_total     = $jobs.Count
        jobs_by_status = $byStatus
        dark_factory   = @($dfJobs | Select-Object -First 8 | ForEach-Object {
            @{ id = $_.id; project = $_.project; status = $_.status; created_at = $_.created_at }
        })
        security_due   = @($sec.due)
        security_count = [int]$sec.count
        curriculum     = $curriculum
        lanes          = @(Get-DarkFactoryLanes | ForEach-Object { $_.lane })
    }
}
