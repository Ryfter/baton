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
