#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:learn runner — backfill outcome ratings from recorded run evidence, and
  report whether the routing-learning loop is alive.
.DESCRIPTION
  learn backfill [--dry-run] [--write] [--json]
    Walk $BATON_HOME/runs/*/tasks/*/verification.json, map terminal outcomes the
    same way as the live executor, append ratings that do not already exist.
    DEFAULT is dry-run (report only). Pass -Write to actually append.

  learn status [--json]
    How many ratings exist, per capability x candidate, with current quality.

  Exit: 0 ok, 1 runtime error, 2 bad usage.
#>
param(
    [Parameter(Position = 0)][string]$Subcommand = 'status',
    [switch]$Json,
    [switch]$DryRun,
    [switch]$Write,
    [string]$RunsRoot = '',
    [string]$RatingsPath = '',
    [string]$FleetPath = '',
    [string]$JournalPath = ''
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'routing-observe-lib.ps1')

function Write-ObserveErr([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

try {
    if (-not $RatingsPath) {
        $RatingsPath = $script:DefaultRatingsPath
    }
    if (-not $RunsRoot) {
        $RunsRoot = Join-Path (Get-BatonHome) 'runs'
    }
    if (-not $FleetPath) {
        $FleetPath = Join-Path (Get-BatonHome) 'fleet.yaml'
    }
    if (-not $JournalPath) {
        $JournalPath = Join-Path (Get-BatonHome) 'routing-journal.jsonl'
    }

    switch -Regex ($Subcommand) {
        '^(?i:backfill)$' {
            # Default dry-run; -Write is the explicit opt-in. -DryRun forces report-only.
            $result = Invoke-RoutingObserveBackfill `
                -RunsRoot $RunsRoot `
                -RatingsPath $RatingsPath `
                -FleetPath $FleetPath `
                -Write:$Write `
                -DryRun:$DryRun

            if ($Json) {
                ConvertTo-Json -InputObject ([pscustomobject]$result) -Depth 8
                exit 0
            }

            $mode = if ($result.dry_run) { 'DRY-RUN' } else { 'WRITE' }
            Write-Host ("learn backfill [{0}]  runs_root={1}" -f $mode, $result.runs_root)
            Write-Host ("  examined={0}  would_write={1}  written={2}  skipped={3}" -f `
                $result.examined, $result.would_write, $result.written, $result.skipped)
            if (@($result.items).Count -gt 0) {
                Write-Host ''
                Write-Host ('  {0,-28} {1,-8} {2,-14} {3,-8} {4}' -f 'RUN/TASK', 'RATING', 'CANDIDATE', 'VERDICT', 'FAIL')
                foreach ($it in @($result.items)) {
                    $rt = '{0}/{1}' -f $it.run_id, $it.task_id
                    if ($rt.Length -gt 28) { $rt = $rt.Substring(0, 25) + '...' }
                    Write-Host ('  {0,-28} {1,-8} {2,-14} {3,-8} {4}' -f `
                        $rt, $it.rating, $it.candidate, $it.verdict, $it.failure_category)
                }
            }
            if ($result.dry_run -and $result.would_write -gt 0) {
                Write-Host ''
                Write-Host '  (default is dry-run; pass -Write to append these ratings)'
            }
            exit 0
        }
        '^(?i:status)$' {
            $status = Get-RoutingObserveStatus -RatingsPath $RatingsPath -JournalPath $JournalPath
            if ($Json) {
                ConvertTo-Json -InputObject ([pscustomobject]$status) -Depth 8
                exit 0
            }

            Write-Host ("learn status  ratings={0}  total={1}  observe={2}" -f `
                $status.ratings_path, $status.total, $(if ($status.observe_on) { 'on' } else { 'off' }))
            if (@($status.pairs).Count -eq 0) {
                Write-Host '  (no ratings yet — loop is starved)'
                exit 0
            }
            Write-Host ''
            Write-Host ('  {0,-16} {1,-18} {2,5} {3,5} {4,5} {5,8}' -f `
                'CAPABILITY', 'CANDIDATE', 'N', 'GOOD', 'BAD', 'QUALITY')
            foreach ($p in @($status.pairs)) {
                Write-Host ('  {0,-16} {1,-18} {2,5} {3,5} {4,5} {5,8:N3}' -f `
                    $p.capability, $p.candidate, $p.n, $p.good, $p.bad, $p.quality)
            }
            exit 0
        }
        default {
            Write-ObserveErr "unknown subcommand: $Subcommand (use backfill | status)"
            exit 2
        }
    }
} catch {
    Write-ObserveErr "learn: $($_.Exception.Message)"
    exit 1
}
