#!/usr/bin/env pwsh
<#
.SYNOPSIS
  PostToolUse hook: append a plain-English event for the active run to the
  legibility feed. No-ops unless $BATON_HOME/runs/current-run.json names a run.
#>
param(
    [string]$RunsRoot    = $(if ($env:ROUTING_RUNS_ROOT) { $env:ROUTING_RUNS_ROOT } elseif ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'runs' } else { Join-Path $HOME '.baton/runs' }),
    [string]$PointerPath,
    [string]$ErrorPath   = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'logs/run-feed.err.log' } else { Join-Path $HOME '.baton/logs/run-feed.err.log' })
)
$ErrorActionPreference = 'Continue'  # never crash Claude Code
if (-not $PointerPath) { $PointerPath = Join-Path $RunsRoot 'current-run.json' }

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
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $libCandidates = @(
        (Join-Path $scriptDir '../runs-lib.ps1'),          # repo layout: scripts/hooks -> scripts
        (Join-Path $scriptDir '../scripts/runs-lib.ps1')   # deployed layout: ~/.claude/hooks -> ~/.claude/scripts
    )
    $libPath = $libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $libPath) { throw "runs-lib.ps1 not found near $scriptDir" }
    . $libPath
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

    # Update run.json: refresh current_step (+ updated_at always); merge files_touched for file-oriented tools
    $setParams = @{ RunsRoot = $RunsRoot; Id = $ptr.id; CurrentStep = $what }
    if ($evt.tool_name -in @('Read','Write','Edit')) {
        $leaf = Split-Path -Leaf $evt.tool_input.file_path
        if ($leaf) {
            $runPath = Join-Path (Get-RunsRoot $RunsRoot) "$($ptr.id)/run.json"
            $existing = @()
            if (Test-Path $runPath) {
                $r = Get-Content $runPath -Raw | ConvertFrom-Json
                if ($r.files_touched) { $existing = @($r.files_touched) }
            }
            if ($existing -notcontains $leaf) { $existing = $existing + $leaf }
            $setParams['FilesTouched'] = [string[]]$existing
        }
    }
    Set-RunRecord @setParams
    exit 0
} catch {
    Write-ErrLog "run-feed hook: $($_.Exception.Message)"
    exit 0
}
