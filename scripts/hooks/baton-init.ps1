#!/usr/bin/env pwsh
<#
.SYNOPSIS
  SessionStart(startup) hook: ensure BATON_HOME exists, seed the config yamls on
  first run, and run the one-time ~/.claude -> BATON_HOME state migration.
  Non-blocking: always exits 0; errors go to $BATON_HOME/logs/baton-init.err.log.
#>
$ErrorActionPreference = 'Continue'
try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $libCandidates = @(
        (Join-Path $scriptDir '../baton-home.ps1'),         # repo/plugin layout: scripts/hooks -> scripts
        (Join-Path $scriptDir '../scripts/baton-home.ps1')  # deployed layout: ~/.claude/hooks -> ~/.claude/scripts
    )
    $libPath = $libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $libPath) { exit 0 }
    . $libPath
    # Migration runs first: Initialize-BatonHome pre-creates the migration's destinations (jobs/, runs/, yamls),
    # which would cause every legacy item to be reported as a conflict and left stranded.
    $mig = Move-BatonState
    foreach ($c in @($mig.conflicts)) { Write-Output "baton-init: state exists in both ~/.claude and BATON_HOME, left in place: $c" }
    $refs = [IO.Path]::GetFullPath((Join-Path $scriptDir '../../references'))
    if (Test-Path $refs) { Initialize-BatonHome -ReferencesDir $refs | Out-Null }
    exit 0
} catch {
    try {
        $log = Join-Path (Get-BatonHome) 'logs/baton-init.err.log'
        $d = Split-Path -Parent $log
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $log -Value ((Get-Date -Format o) + " | " + $_.Exception.Message)
    } catch { }
    exit 0
}

