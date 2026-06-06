#!/usr/bin/env pwsh
<#
.SYNOPSIS
  PostToolUse hook: append a plain-English event for the active run to the
  legibility feed. No-ops unless ~/.claude/current-run.json names a run.
#>
param(
    [string]$RunsRoot    = $(if ($env:ROUTING_RUNS_ROOT) { $env:ROUTING_RUNS_ROOT } else { Join-Path $HOME '.claude/runs' }),
    [string]$PointerPath = (Join-Path $HOME '.claude/current-run.json'),
    [string]$ErrorPath   = (Join-Path $HOME '.claude/hooks/run-feed.err.log')
)
$ErrorActionPreference = 'Continue'  # never crash Claude Code

function Write-ErrLog($m) {
    try {
        $d = Split-Path -Parent $ErrorPath
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $ErrorPath -Value ((Get-Date -Format o) + " | " + $m)
    } catch { }
}

function Narrate($tool, $inp) {
    switch ($tool) {
        'Read'      { return "read $(Split-Path -Leaf $inp.file_path)" }
        'Write'     { return "wrote $(Split-Path -Leaf $inp.file_path)" }
        'Edit'      { return "edited $(Split-Path -Leaf $inp.file_path)" }
        'Grep'      { return "searched for `"$($inp.pattern)`"" }
        'Glob'      { return "listed files matching $($inp.pattern)" }
        'Bash'      { $c = "$($inp.command)"; if ($c.Length -gt 60) { $c = $c.Substring(0,60) + '…' }; return "ran: $c" }
        'PowerShell'{ $c = "$($inp.command)"; if ($c.Length -gt 60) { $c = $c.Substring(0,60) + '…' }; return "ran: $c" }
        'Agent'     { return "dispatched a subagent: $($inp.description)" }
        default     { return $null }
    }
}

try {
    . "$PSScriptRoot/../runs-lib.ps1"
    if (-not (Test-Path $PointerPath)) { exit 0 }
    $ptr = Get-Content $PointerPath -Raw | ConvertFrom-Json
    if (-not $ptr.id) { exit 0 }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $evt = $raw | ConvertFrom-Json
    $what = Narrate $evt.tool_name $evt.tool_input
    if (-not $what) { exit 0 }
    $status = if ($null -ne $evt.tool_response.exit_code -and $evt.tool_response.exit_code -ne 0) { 'failed' } else { 'done' }
    Add-RunEvent -RunsRoot $RunsRoot -Id $ptr.id -Kind 'action' -What $what -Status $status
    exit 0
} catch {
    Write-ErrLog "run-feed hook: $($_.Exception.Message)"
    exit 0
}
