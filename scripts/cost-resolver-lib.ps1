#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Realized-Cost Metering for Baton Tasks.
.DESCRIPTION
  Parses logs from the underlying provider CLI (e.g. Claude Code) to calculate
  exact token spend for a given task, based on its runtime window.
#>

. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"

# Prices per 1,000,000 tokens (USD)
$script:ClaudePrices = @{
    'claude-3-5-sonnet-20241022' = @{ in = 3.00; out = 15.00 }
    'claude-3-5-haiku-20241022'  = @{ in = 0.80; out = 4.00 }
    'claude-3-haiku-20240307'    = @{ in = 0.25; out = 1.25 }
    'claude-3-opus-20240229'     = @{ in = 15.00; out = 75.00 }

    # Current Baton fleet.yaml pinned models
    'claude-sonnet-5'            = @{ in = 3.00; out = 15.00 }
    'claude-haiku-4-5-20251001'  = @{ in = 1.00; out = 5.00 }
}

function Get-ClaudeCodeCost {
    <#
    .SYNOPSIS
      Parses ~/.claude/projects/**/*.jsonl for 'usage' events within a window.
    .DESCRIPTION
      Attribution heuristic: candidate files are filtered by CreationTimeUtc
      (NOT LastWriteTimeUtc) at-or-after the window start. A dispatched Claude
      Code CLI run creates a brand-new session log file inside the window it
      runs in, so filtering on creation time isolates that run's own log from
      the long-running orchestrating session's log — which was created well
      before the window and, under a LastWriteTime filter, would get swept in
      and over-attribute the orchestrator's own token spend to the task.
    .NOTES
      Limit: a RESUMED session (`claude -r` / `--resume`) appends to a log
      file created in an earlier window, so a resumed dispatch's usage events
      won't be picked up by this creation-time filter and will escape
      metering here. Callers (Get-RealizedTaskCost) fall back to the
      cost-tier estimate whenever the metered total comes back 0, which
      covers this case.
    #>
    param(
        [Parameter(Mandatory)][datetime]$StartTime,
        [Parameter(Mandatory)][datetime]$EndTime,
        [string]$ClaudeLogDir = (Join-Path $HOME '.claude/projects')
    )
    if (-not (Test-Path $ClaudeLogDir)) { return 0.0 }

    # Buffer the window to account for file I/O delays. Use UTC to avoid zone bugs.
    $startUtc = $StartTime.ToUniversalTime().AddSeconds(-2)
    $endUtc = $EndTime.ToUniversalTime().AddSeconds(5)

    $totalCost = 0.0

    # Only look at log files CREATED at-or-after the window start (see heuristic above).
    $candidateFiles = Get-ChildItem -Path $ClaudeLogDir -Recurse -Filter "*.jsonl" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTimeUtc -ge $startUtc }

    foreach ($file in $candidateFiles) {
        $lines = Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            # Fast string check before parsing JSON
            if ($line -notmatch '"usage"') { continue }

            try {
                $ev = $line | ConvertFrom-Json
                if ($ev.timestamp -and $ev.message.usage) {
                    $tsUtc = ([datetime]$ev.timestamp).ToUniversalTime()
                    if ($tsUtc -ge $startUtc -and $tsUtc -le $endUtc) {
                        $model = if ($ev.message.model) { [string]$ev.message.model } else { '' }
                        $usage = $ev.message.usage

                        if (-not $script:ClaudePrices.Contains($model)) {
                            # Unknown (or missing) model: skip this event rather than
                            # silently pricing it as sonnet. A wrong-but-nonzero total
                            # would mask itself and never trigger the caller's
                            # estimate fallback — better to under-count and let the
                            # zero-total path hand off to the cost-tier estimate.
                            continue
                        }
                        $prices = $script:ClaudePrices[$model]

                        $inTokens = if ($null -ne $usage.input_tokens) { [double]$usage.input_tokens } else { 0.0 }
                        $outTokens = if ($null -ne $usage.output_tokens) { [double]$usage.output_tokens } else { 0.0 }

                        $cacheWrite = if ($null -ne $usage.cache_creation_input_tokens) { [double]$usage.cache_creation_input_tokens } else { 0.0 }
                        $cacheRead = if ($null -ne $usage.cache_read_input_tokens) { [double]$usage.cache_read_input_tokens } else { 0.0 }

                        # Cache creation is 1.25x base input cost
                        $inWriteCost = ($cacheWrite * ($prices.in * 1.25)) / 1000000.0
                        # Cache read is 0.10x base input cost
                        $inReadCost = ($cacheRead * ($prices.in * 0.10)) / 1000000.0
                        # Base input cost
                        $inBaseCost = ($inTokens * $prices.in) / 1000000.0
                        # Base output cost
                        $outCost = ($outTokens * $prices.out) / 1000000.0

                        $totalCost += ($inWriteCost + $inReadCost + $inBaseCost + $outCost)
                    }
                }
            } catch {
                # Ignore JSON parse errors on malformed lines
                continue
            }
        }
    }
    return [math]::Round($totalCost, 4)
}

function Get-RealizedTaskCost {
    <#
    .SYNOPSIS
      Main resolver entry point: given a task object and its RunDir, determines the
      exact cost by cross-referencing events.jsonl timestamps with platform logs.
    .DESCRIPTION
      -ClaudeLogDir is a test seam: production callers rely on the default
      (the real ~/.claude/projects), tests redirect it to a hermetic temp dir.
    #>
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$RunDir,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ClaudeLogDir = (Join-Path $HOME '.claude/projects')
    )
    $fallbackCost = if ($null -ne $Task.cost) { [double]$Task.cost } else { 0.0 }

    # Find the timestamps for this task from events.jsonl
    $eventsPath = Join-Path $RunDir 'events.jsonl'
    if (-not (Test-Path $eventsPath)) { return $fallbackCost }

    $startTime = $null
    $endTime = $null
    $rawEvents = Get-Content -LiteralPath $eventsPath -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $rawEvents) { return $fallbackCost }

    foreach ($ev in @($rawEvents)) {
        if ($ev.task_id -eq $Task.id) {
            if ($ev.kind -eq 'started') { $startTime = [datetime]$ev.ts }
            if ($ev.kind -in @('finished', 'error')) { $endTime = [datetime]$ev.ts }
        }
    }

    if ($null -eq $startTime -or $null -eq $endTime) { return $fallbackCost }

    # Resolve platform from worker
    $workerName = $Task.worker
    if ([string]::IsNullOrWhiteSpace($workerName)) { return $fallbackCost }
    if (-not (Test-Path $FleetPath)) { return $fallbackCost }

    $provider = $null
    try { $provider = Get-FleetProvider -Name $workerName -Path $FleetPath } catch { }
    if (-not $provider -or -not $provider.platform) { return $fallbackCost }

    if ($provider.platform -eq 'claude') {
        $cost = Get-ClaudeCodeCost -StartTime $startTime -EndTime $endTime -ClaudeLogDir $ClaudeLogDir
        if ($cost -gt 0) { return $cost }
    }

    # Fallback to estimate if platform unsupported or zero cost found
    return $fallbackCost
}
