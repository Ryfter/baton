#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared PowerShell library for the /baton:start front porch (slice 1).
  Dot-source from the start/init/initialize command scripts.

.DESCRIPTION
  Pure resolvers (mode/depth/teaching-level, CHARTER content, resume status,
  next-command recommendation) plus thin seamed I/O for two box-private
  JSON stores: per-project project.json and one user-profile.json.
#>

. "$PSScriptRoot/baton-home.ps1"

function Resolve-StartMode {
    param([object]$ProjectRecord)
    if ($null -eq $ProjectRecord) { return 'new' }
    return 'resume'
}

function Resolve-InterviewDepth {
    param(
        [object]$Profile,
        [string]$Explicit
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if ($null -eq $Profile) { return 'full' }
    if (-not [string]::IsNullOrWhiteSpace($Profile.preferred_interview_depth)) {
        return $Profile.preferred_interview_depth
    }
    return 'adaptive'
}

function Resolve-TeachingLevel {
    param(
        [object]$Profile,
        [string]$Explicit
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if ($null -eq $Profile) { return 'teach' }
    if (-not [string]::IsNullOrWhiteSpace($Profile.teaching_level)) {
        return $Profile.teaching_level
    }
    return 'teach'
}

$script:NextCommandMap = @{
    'completed' = @{
        command = '/baton:gate (review quality) or /baton:effective-cost (see spend)'
        why     = 'the run finished — checking quality or cost is the natural next step before starting something new'
    }
    'interrupted-budget' = @{
        command = 're-run /baton:start (or /baton:go) with a higher --budget'
        why     = 'the next task would cross the budget cap you set, so it paused rather than spend past it'
    }
    'interrupted-destructive' = @{
        command = 'approve the pending step, then resume'
        why     = 'the next task touches something hard to undo (master, a force-push, an external publish), so it paused for your OK'
    }
    'rejected' = @{
        command = '/baton:gate to see the findings, then re-run'
        why     = 'the acceptance gate reviewed the finished work and flagged it — the work still ran, this is a quality verdict'
    }
    'failed' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'a task could not complete — a clearer or narrower goal usually unblocks it'
    }
    'plan-failed' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'planning could not produce a usable set of steps from the goal as stated'
    }
    'plan-invalid' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'planning produced a set of steps that did not check out — a sharper goal usually fixes this'
    }
}

function Get-NextCommandRecommendation {
    param([Parameter(Mandatory)][string]$RunStatus)
    if ($script:NextCommandMap.ContainsKey($RunStatus)) {
        return $script:NextCommandMap[$RunStatus]
    }
    return @{ command = '/baton:start'; why = 'status not recognized — starting fresh is the safest next step' }
}

function Read-ProjectRecord {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$ProjectsRoot = (Join-Path (Get-BatonHome) 'projects')
    )
    $path = Join-Path (Join-Path $ProjectsRoot $ProjectId) 'project.json'
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Debug "Read-ProjectRecord: $($_.Exception.Message)"
        return $null
    }
}

function Write-ProjectRecord {
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [string]$ProjectsRoot = (Join-Path (Get-BatonHome) 'projects')
    )
    $dir = Join-Path $ProjectsRoot $Record.id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-Path $dir 'project.json'
    $Record | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding utf8NoBOM
}

function Read-UserProfile {
    param([string]$ProfilePath = (Join-Path (Get-BatonHome) 'user-profile.json'))
    if (-not (Test-Path $ProfilePath)) { return $null }
    try {
        $raw = Get-Content $ProfilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Debug "Read-UserProfile: $($_.Exception.Message)"
        return $null
    }
}

function Write-UserProfile {
    param(
        [Parameter(Mandatory)][hashtable]$Profile,
        [string]$ProfilePath = (Join-Path (Get-BatonHome) 'user-profile.json')
    )
    $dir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Profile | ConvertTo-Json -Depth 6 | Set-Content -Path $ProfilePath -Encoding utf8NoBOM
}

function New-CharterContent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Goal,
        [string]$Audience,
        [string]$Done,
        [string]$Reasoning
    )
    $today = Get-Date -Format 'yyyy-MM-dd'
    $audienceText  = if ([string]::IsNullOrWhiteSpace($Audience))  { '(to be filled in)' } else { $Audience }
    $doneText      = if ([string]::IsNullOrWhiteSpace($Done))      { '(to be filled in)' } else { $Done }
    $reasoningText = if ([string]::IsNullOrWhiteSpace($Reasoning)) { '(to be filled in)' } else { $Reasoning }

    @"
# $Name — Project Charter

_Written by /baton:start on $today. Your plain-language record of what we're building and why._

## What we're building
$Goal

## Who it's for
$audienceText

## What "done" looks like
$doneText

## Why — the reasoning
$reasoningText

## Decisions & open questions
(to be filled in as the project moves along)

---
_Baton tracks the technical run history privately under its own home; this file is yours._
"@
}

function Format-ResumeStatus {
    param([Parameter(Mandatory)][object]$ProjectRecord)
    $name = $ProjectRecord.name
    $folder = $ProjectRecord.folder
    if ($null -eq $ProjectRecord.last_run) {
        return "Project '$name' at $folder hasn't run yet — pick up where onboarding left off, or describe what to build."
    }
    $status = $ProjectRecord.last_run.status
    $at = $ProjectRecord.last_run.at
    return "Project '$name' at $folder — last run ($at) ended with status '$status'."
}
