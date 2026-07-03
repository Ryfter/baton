#!/usr/bin/env pwsh
<#
.SYNOPSIS
  SessionStart(startup) hook: guided-use orientation digest (d074).
  Read-only except the one-shot onboard stamp. Non-blocking: always exits 0;
  errors go to $BATON_HOME/logs/baton-coach.err.log. Runs after
  baton-init.ps1 (registered earlier in hooks/hooks.json), so BATON_HOME
  exists by the time this fires — if it still doesn't, stay silent.
#>
$ErrorActionPreference = 'Continue'
try {
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $libCandidates = @(
        (Join-Path $scriptDir '../coach-lib.ps1'),         # repo/plugin layout: scripts/hooks -> scripts
        (Join-Path $scriptDir '../scripts/coach-lib.ps1')  # deployed layout: ~/.claude/hooks -> ~/.claude/scripts
    )
    $libPath = $libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $libPath) { exit 0 }
    . $libPath

    $batonHome = Get-BatonHome
    if (-not (Test-Path $batonHome)) { exit 0 }
    $level = Get-CoachLevel -BatonHome $batonHome
    if ($level -eq 'off') { exit 0 }

    # cwd from the hook's stdin JSON payload; fall back to the process cwd.
    $projDir = (Get-Location).Path
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw) {
                $payload = $raw | ConvertFrom-Json
                if ($payload.cwd) { $projDir = [string]$payload.cwd }
            }
        }
    } catch { }

    $ctx = Get-CoachContext -BatonHome $batonHome -ProjectDir $projDir
    $seenPath = Join-Path (Get-CoachDir -BatonHome $batonHome) 'seen.json'

    if ($ctx.project) {
        # Registered project: status digest (never dedups) + top suggestion.
        $status = if ($ctx.project.last_run -and $ctx.project.last_run.status) { [string]$ctx.project.last_run.status } else { 'no runs yet' }
        Write-Output ("Baton coach — project '{0}': last run {1}." -f $ctx.project_id, $status)
        if ($ctx.pool_ok) {
            $challStr = if ($ctx.pool_challenger_id) { "challenger $($ctx.pool_challenger_id) ($($ctx.pool_verdict_state))" } else { 'no challenger' }
            Write-Output ("Prompt pool: champion {0}, {1}." -f $ctx.pool_champion_id, $challStr)
        }
        $budgetStr = if ($ctx.conserve) { 'CONSERVE MODE ON' } elseif ($ctx.budget_at_risk) { 'budget at risk' } else { 'budget ok' }
        Write-Output ("Usage: {0}." -f $budgetStr)
        $sugg = @(Get-CoachSuggestions -Context $ctx -SeenPath $seenPath -IncludeSeen)
        if (@($sugg).Count -gt 0) {
            $top = $sugg[0]
            if ($level -eq 'teach') { Write-Output ("Suggested next: {0} — {1}" -f $top.command, $top.why) }
            else { Write-Output ("Suggested next: {0}" -f $top.command) }
        }
    } elseif ($ctx.is_git_repo) {
        # Unregistered repo: one-shot onboard push line (stamped).
        $sugg = @(Get-CoachSuggestions -Context $ctx -SeenPath $seenPath | Where-Object { $_.id -eq 'onboard' })
        if (@($sugg).Count -gt 0) {
            $onboard = $sugg[0]
            if ($level -eq 'teach') { Write-Output ("Baton available: {0} — {1}" -f $onboard.command, $onboard.why) }
            else { Write-Output ("Baton available — {0} to onboard." -f $onboard.command) }
            Set-CoachSeen -SeenPath $seenPath -Key ([string]$onboard.dedup_key)
        }
    }
    exit 0
} catch {
    try {
        $log = Join-Path (Get-BatonHome) 'logs/baton-coach.err.log'
        $d = Split-Path -Parent $log
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $log -Value ((Get-Date -Format o) + " | " + $_.Exception.Message)
    } catch { }
    exit 0
}
