#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Tests for cost-resolver-lib.ps1 (house Check/PASS-FAIL style — Pester
  failures don't propagate exit codes reliably here; this suite is
  exit-code gated).
.DESCRIPTION
  Hermetic: every path is a temp dir under the OS temp path; never reads or
  writes the real ~/.claude or ~/.baton.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cost-resolver-lib.ps1')

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

function New-TempDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("cost-rdr-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

try {
    # ---- Get-ClaudeCodeCost: cache math (1.25x write / 0.10x read) ----
    $logDir1 = Join-Path (New-TempDir) 'claude_logs'
    New-Item -ItemType Directory -Force -Path $logDir1 | Out-Null
    '{"type":"assistant","timestamp":"2026-07-01T10:00:01Z","message":{"model":"claude-3-5-sonnet-20241022","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":50}}}' |
        Set-Content -Path (Join-Path $logDir1 'log1.jsonl') -Encoding utf8NoBOM

    $start1 = [datetime]'2026-07-01T10:00:00Z'
    $end1 = [datetime]'2026-07-01T10:00:05Z'
    # Math: in=3.00, out=15.00
    #   inBase     = 100 * 3 / 1e6      = 0.0003
    #   outBase    = 50 * 15 / 1e6      = 0.00075
    #   cacheWrite = 200 * (3*1.25)/1e6 = 0.00075
    #   cacheRead  = 50 * (3*0.10)/1e6  = 0.000015
    #   total = 0.001815 -> rounded to 4dp = 0.0018
    $cost1 = Get-ClaudeCodeCost -StartTime $start1 -EndTime $end1 -ClaudeLogDir $logDir1
    Check 'C1 cache-write/cache-read math (1.25x/0.10x) rounds to 0.0018' ($cost1 -eq 0.0018)

    # ---- Get-ClaudeCodeCost: out-of-window usage event ignored ----
    $logDir2 = Join-Path (New-TempDir) 'claude_logs_2'
    New-Item -ItemType Directory -Force -Path $logDir2 | Out-Null
    '{"type":"assistant","timestamp":"2026-07-01T10:00:15Z","message":{"model":"claude-3-5-sonnet-20241022","usage":{"input_tokens":1000,"output_tokens":500}}}' |
        Set-Content -Path (Join-Path $logDir2 'log1.jsonl') -Encoding utf8NoBOM
    $cost2 = Get-ClaudeCodeCost -StartTime $start1 -EndTime $end1 -ClaudeLogDir $logDir2
    Check 'C2 out-of-window usage event ignored (cost 0)' ($cost2 -eq 0)

    # ---- Get-ClaudeCodeCost: unknown model is skipped, not priced as sonnet ----
    $logDir3 = Join-Path (New-TempDir) 'claude_logs_3'
    New-Item -ItemType Directory -Force -Path $logDir3 | Out-Null
    '{"type":"assistant","timestamp":"2026-07-01T10:00:01Z","message":{"model":"totally-unknown-model","usage":{"input_tokens":1000,"output_tokens":1000}}}' |
        Set-Content -Path (Join-Path $logDir3 'log1.jsonl') -Encoding utf8NoBOM
    $cost3 = Get-ClaudeCodeCost -StartTime $start1 -EndTime $end1 -ClaudeLogDir $logDir3
    Check 'C3 unknown model contributes 0 (not silently priced as sonnet)' ($cost3 -eq 0)

    # ---- Price table spot-checks ----
    Check 'C4 haiku 3.5 corrected to 0.80/4.00' (($script:ClaudePrices['claude-3-5-haiku-20241022'].in -eq 0.80) -and ($script:ClaudePrices['claude-3-5-haiku-20241022'].out -eq 4.00))
    Check 'C5 fictional claude-sonnet-4-6 key removed' (-not $script:ClaudePrices.Contains('claude-sonnet-4-6'))
    Check 'C6 claude-sonnet-5 priced 3.00/15.00' (($script:ClaudePrices['claude-sonnet-5'].in -eq 3.00) -and ($script:ClaudePrices['claude-sonnet-5'].out -eq 15.00))
    Check 'C7 claude-haiku-4-5-20251001 kept at 1.00/5.00' (($script:ClaudePrices['claude-haiku-4-5-20251001'].in -eq 1.00) -and ($script:ClaudePrices['claude-haiku-4-5-20251001'].out -eq 5.00))

    # ---- Get-RealizedTaskCost: end-to-end via the -ClaudeLogDir seam ----
    $now = (Get-Date).ToUniversalTime()
    $tsFmt = 'yyyy-MM-ddTHH:mm:ssZ'
    $wStart = $now.AddSeconds(-60)
    $wEnd = $now.AddSeconds(60)

    $runDir = New-TempDir
    $eventsPath = Join-Path $runDir 'events.jsonl'
    @(
        (@{ task_id = 't1'; kind = 'started'; ts = $wStart.ToString($tsFmt) } | ConvertTo-Json -Compress),
        (@{ task_id = 't1'; kind = 'finished'; ts = $wEnd.ToString($tsFmt) } | ConvertTo-Json -Compress)
    ) | Set-Content -LiteralPath $eventsPath -Encoding utf8NoBOM

    $fleetPath = Join-Path $runDir 'fleet.yaml'
    @'
providers:
  - name: test-claude
    kind: cli
    enabled: true
    cost_tier: paid
    role: finisher
    platform: claude
    command_template: 'echo "{{prompt}}"'
'@ | Set-Content -LiteralPath $fleetPath -Encoding utf8NoBOM

    $claudeLogDir = Join-Path $runDir 'claude-logs'
    New-Item -ItemType Directory -Force -Path $claudeLogDir | Out-Null
    # model claude-sonnet-5: in=3.00/out=15.00 -> 1000*3/1e6 + 500*15/1e6 = 0.003+0.0075 = 0.0105
    (@{ type = 'assistant'; timestamp = $now.ToString($tsFmt); message = @{ model = 'claude-sonnet-5'; usage = @{ input_tokens = 1000; output_tokens = 500 } } } | ConvertTo-Json -Compress -Depth 5) |
        Set-Content -LiteralPath (Join-Path $claudeLogDir 'session1.jsonl') -Encoding utf8NoBOM

    $task = @{ id = 't1'; worker = 'test-claude'; cost = 0.05 }
    $realized = Get-RealizedTaskCost -Task $task -RunDir $runDir -FleetPath $fleetPath -ClaudeLogDir $claudeLogDir
    Check 'C8 end-to-end metered cost via the -ClaudeLogDir seam' ($realized -eq 0.0105)

    # ---- Fallback: events.jsonl missing ----
    $runDirNoEvents = New-TempDir
    $noEventsCost = Get-RealizedTaskCost -Task $task -RunDir $runDirNoEvents -FleetPath $fleetPath -ClaudeLogDir $claudeLogDir
    Check 'C9 missing events.jsonl -> estimate fallback' ($noEventsCost -eq 0.05)

    # ---- Fallback: unknown worker ----
    $taskUnknownWorker = @{ id = 't1'; worker = 'no-such-worker'; cost = 0.07 }
    $unkCost = Get-RealizedTaskCost -Task $taskUnknownWorker -RunDir $runDir -FleetPath $fleetPath -ClaudeLogDir $claudeLogDir
    Check 'C10 unknown worker -> estimate fallback' ($unkCost -eq 0.07)

    # ---- Fallback: metered total is 0 (empty claude log dir) ----
    $emptyLogDir = New-TempDir
    $taskEmptyLogs = @{ id = 't1'; worker = 'test-claude'; cost = 0.09 }
    $emptyCost = Get-RealizedTaskCost -Task $taskEmptyLogs -RunDir $runDir -FleetPath $fleetPath -ClaudeLogDir $emptyLogDir
    Check 'C11 zero metered total -> estimate fallback' ($emptyCost -eq 0.09)

    # ---- Fallback: unknown model in the log -> skipped -> zero total -> estimate fallback ----
    $unknownModelLogDir = Join-Path (New-TempDir) 'unknown-model-logs'
    New-Item -ItemType Directory -Force -Path $unknownModelLogDir | Out-Null
    (@{ type = 'assistant'; timestamp = $now.ToString($tsFmt); message = @{ model = 'some-future-model-xyz'; usage = @{ input_tokens = 1000; output_tokens = 1000 } } } | ConvertTo-Json -Compress -Depth 5) |
        Set-Content -LiteralPath (Join-Path $unknownModelLogDir 'session1.jsonl') -Encoding utf8NoBOM
    $taskUnknownModel = @{ id = 't1'; worker = 'test-claude'; cost = 0.11 }
    $unkModelCost = Get-RealizedTaskCost -Task $taskUnknownModel -RunDir $runDir -FleetPath $fleetPath -ClaudeLogDir $unknownModelLogDir
    Check 'C12 unknown model in log -> skipped -> estimate fallback' ($unkModelCost -eq 0.11)

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
