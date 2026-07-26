#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:heartbeat runner. Pin the 5-hour usage window to a clock time you chose, and
  fold the free housekeeping (expired lockouts, session liveness) into the same tick.
.DESCRIPTION
  -Status            show the anchor and the next boundary; spends nothing.
  -Anchor "<time>"   seed the anchor ('3:50', '03:50', or a full timestamp).
  -Now               fire a beat immediately.
  -SkipAnchor        run only the free half (no model call).
  -Reschedule        after firing, register the next one-shot task (used by the task itself).
  -Install           register the next beat without firing one now.
  -Uninstall         remove the scheduled task.
  -PrintSchedule     print the schtasks command instead of running it.
#>
param(
    [switch]$Status,
    [string]$Anchor,
    [switch]$Now,
    [switch]$SkipAnchor,
    [switch]$Reschedule,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$PrintSchedule,
    [switch]$Json,
    [string]$Model = 'haiku',
    [int]$EpsilonSeconds = 60,
    [string]$TaskName = 'BatonUsageHeartbeat',
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { $null })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'heartbeat-lib.ps1')

function Write-HbErr([string]$m) { [Console]::Error.WriteLine($m) }

try {
    if (-not $BatonHome) { $BatonHome = Get-BatonHome }
    $statePath = Get-HeartbeatStatePath -BatonHome $BatonHome
    $nowOffset = [datetimeoffset]::Now

    if ($Uninstall) {
        $out = & schtasks /Delete /F /TN $TaskName 2>&1
        Write-Output ("heartbeat: removed scheduled task '{0}' ({1})" -f $TaskName, (@($out) -join ' ').Trim())
        exit 0
    }

    # Seed / re-seed the anchor.
    if ($PSBoundParameters.ContainsKey('Anchor') -and $Anchor) {
        $resolved = Resolve-HeartbeatAnchor -Anchor $Anchor -Now $nowOffset
        if (-not $resolved) {
            Write-HbErr "heartbeat: could not read '$Anchor' as a time. Use '3:50', '03:50', or a full timestamp."
            exit 2
        }
        $state = Read-HeartbeatState -Path $statePath
        $state.anchor = $resolved.ToString('o')
        # An operator-supplied anchor is a RESET time, so it still needs the +epsilon offset.
        $state.anchor_from_beat = $false
        [void](Write-HeartbeatState -State $state -Path $statePath)
        Write-Output ("heartbeat: anchored to {0}" -f $resolved.ToString('yyyy-MM-dd HH:mm:ss zzz'))
    }

    $state = Read-HeartbeatState -Path $statePath
    $anchorAt = if ($state.anchor) { Resolve-HeartbeatAnchor -Anchor ([string]$state.anchor) -Now $nowOffset } else { $null }

    if ($Status -or (-not $Now -and -not $Install -and -not $PSBoundParameters.ContainsKey('Anchor'))) {
        if (-not $anchorAt) {
            Write-Output 'heartbeat: no anchor set. Seed it with the time your window resets, e.g.:'
            Write-Output '    /baton:heartbeat --anchor "3:50"'
            exit 0
        }
        $eps = Get-HeartbeatEpsilon -State $state -Requested $EpsilonSeconds
        $next = Get-NextHeartbeatBoundary -Anchor $anchorAt -Now $nowOffset -EpsilonSeconds $eps
        $mins = [int][math]::Round($next.seconds_until / 60)
        if ($Json) {
            ConvertTo-Json -InputObject ([ordered]@{
                anchor = $anchorAt.ToString('o'); next_at = $next.boundary_at.ToString('o')
                minutes_until = $mins; beats = $state.beats; last_fired_at = $state.last_fired_at
            }) -Depth 5
        } else {
            Write-Output ("heartbeat: anchor {0} | next beat {1} (in {2} min) | beats so far {3}" -f `
                $anchorAt.ToString('HH:mm:ss'), $next.boundary_at.ToString('yyyy-MM-dd HH:mm:ss'), $mins, $state.beats)
        }
        if (-not $Install) { exit 0 }
    }

    $result = $null
    if ($Now) {
        $result = Invoke-UsageHeartbeat -SkipAnchor:$SkipAnchor -Model $Model -BatonHome $BatonHome -Now $nowOffset
        if ($Json) {
            ConvertTo-Json -InputObject $result -Depth 8
        } else {
            $a = $result.anchor
            if ($a.ok -and [string]$a.reason -ne 'skipped') {
                Write-Output ("heartbeat: anchored — {0} tok in / {1} tok out{2}" -f `
                    $a.input_tokens, $a.output_tokens, $(if ($null -ne $a.cost_usd) { " (`$$([math]::Round([double]$a.cost_usd,4)))" } else { '' }))
            } elseif ([string]$a.reason -eq 'skipped') {
                Write-Output 'heartbeat: anchor skipped (free half only)'
            } else {
                Write-Output ("heartbeat: anchor FAILED — {0} (free housekeeping still ran)" -f $a.reason)
            }
            if (@($result.cleared_workers).Count -gt 0) {
                Write-Output ("heartbeat: cleared expired lockouts — {0}" -f (@($result.cleared_workers) -join ', '))
            }
            Write-Output ("heartbeat: {0} live session(s) stamped" -f $result.liveness.live_sessions)
            if ($result.next) {
                Write-Output ("heartbeat: next beat {0}" -f $result.next.boundary_at.ToString('yyyy-MM-dd HH:mm:ss'))
            }
        }
    }

    if ($Install -or $Reschedule) {
        $state = Read-HeartbeatState -Path $statePath
        $anchorAt = if ($state.anchor) { Resolve-HeartbeatAnchor -Anchor ([string]$state.anchor) -Now $nowOffset } else { $null }
        if (-not $anchorAt) {
            Write-HbErr 'heartbeat: cannot schedule without an anchor. Run --anchor "<reset time>" first.'
            exit 2
        }
        $eps = Get-HeartbeatEpsilon -State $state -Requested $EpsilonSeconds
        $next = Get-NextHeartbeatBoundary -Anchor $anchorAt -Now $nowOffset -EpsilonSeconds $eps
        $cmd = @(Get-HeartbeatScheduleCommand -At $next.boundary_at -TaskName $TaskName)
        if ($PrintSchedule) {
            Write-Output ($cmd -join ' ')
            exit 0
        }
        $exe = $cmd[0]
        $rest = @($cmd | Select-Object -Skip 1)
        $out = & $exe @rest 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-HbErr ("heartbeat: schtasks failed (exit {0}): {1}" -f $LASTEXITCODE, ((@($out) -join ' ').Trim()))
            exit 2
        }
        Write-Output ("heartbeat: next beat scheduled {0} (task '{1}')" -f $next.boundary_at.ToString('yyyy-MM-dd HH:mm:ss'), $TaskName)
    }
    exit 0
} catch {
    Write-HbErr ("heartbeat: {0}" -f $_.Exception.Message)
    exit 2
}
