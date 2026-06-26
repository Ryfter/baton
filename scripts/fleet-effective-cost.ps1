#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:effective-cost runner. Folds the per-run effective-cost.json records
  (written by /baton:go when a gate verdict exists) into a per-worker learned
  leaderboard — cheapest quality-adjusted worker first. Advisory only.
.DESCRIPTION
  Reads box-private records under $BATON_HOME/runs/*/effective-cost.json (or an
  explicit -Runs glob), folds via Get-WorkerEffectiveCost, and prints the
  leaderboard (or -Json: the raw rows array). No side effects, no routing change.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'report',
    [switch]$Json,
    [string]$Runs,
    [int]$MinConfidenceRuns = 5,
    [string]$RunsRoot = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'runs' } else { Join-Path $HOME '.baton/runs' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'effective-cost-lib.ps1')

function Read-EffectiveCostRecords {
    <# Glob effective-cost.json records and parse them; a malformed file is
       skipped, never fatal. Returns an array (possibly empty). #>
    param([string]$Root, [string]$Glob)
    $pattern = if ($Glob) { $Glob } else { Join-Path $Root '*/effective-cost.json' }
    $records = @()
    foreach ($f in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) {
        try { $records += (Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json) }
        catch { [Console]::Error.WriteLine("skipped unreadable record: $($f.FullName)") }
    }
    return ,@($records)
}

switch ($Subcommand) {
    'report' {
        $records = Read-EffectiveCostRecords -Root $RunsRoot -Glob $Runs
        $board = Get-WorkerEffectiveCost -Records @($records) -MinConfidenceRuns $MinConfidenceRuns
        if ($Json) {
            # -InputObject (not pipe): a piped array unrolls, so ConvertTo-Json
            # would emit a bare object for 1 row and nothing for 0 rows. Force a
            # real JSON array for every N so the rows-array contract holds.
            ConvertTo-Json -InputObject @($board) -Depth 6
        }
        else {
            Write-Host (Format-EffectiveCostLeaderboard -Rows @($board) -RunCount (@($records).Count))
        }
        return
    }
    default { [Console]::Error.WriteLine("unknown subcommand: $Subcommand (use report)"); exit 2 }
}
