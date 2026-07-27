#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:window-service runner. Lazy per-project hygiene + candidates + briefing
  keyed on the 5-hour usage-window grid (issue #147).
.DESCRIPTION
  -Status            show due/last-serviced for this project; spends nothing.
  -Now               service this project immediately (ignores the claim mutex).
  -Project <path>    project directory (default: cwd).
  -Json              machine-readable output.
#>
param(
    [switch]$Status,
    [switch]$Now,
    [string]$Project,
    [switch]$Json,
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { $null })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'window-service-lib.ps1')

function Write-WsErr([string]$m) { [Console]::Error.WriteLine($m) }

try {
    if (-not $BatonHome) { $BatonHome = Get-BatonHome }
    $projectDir = if ($Project) { $Project } else { (Get-Location).Path }
    try { $projectDir = [System.IO.Path]::GetFullPath($projectDir) } catch { }

    $nowOffset = [datetimeoffset]::Now

    if ($Status -or (-not $Now)) {
        $st = Get-WindowServiceStatus -ProjectDir $projectDir -BatonHome $BatonHome -Now $nowOffset
        if ($Json) {
            ConvertTo-Json -InputObject $st -Depth 6
        } else {
            if ($st.dormant) {
                Write-Output 'window-service: dormant (no heartbeat anchor). Seed with /baton:heartbeat --anchor "<reset time>".'
            } else {
                Write-Output ("window-service: project {0}" -f $st.project_dir)
                Write-Output ("window-service: serial {0} | due={1} | enabled={2} candidates={3}" -f `
                    $st.serial, $st.due, $st.enabled, $st.candidates_enabled)
                if ($null -ne $st.last_stamp_serial) {
                    Write-Output ("window-service: last serviced serial {0} at {1}" -f $st.last_stamp_serial, $st.last_claimed_at)
                } else {
                    Write-Output 'window-service: never serviced this project'
                }
                Write-Output ("window-service: briefing {0}" -f $(if ($st.briefing_exists) { 'present' } else { 'absent' }))
            }
        }
        if (-not $Now) { exit 0 }
    }

    if ($Now) {
        $state = Read-HeartbeatState -Path (Get-HeartbeatStatePath -BatonHome $BatonHome)
        $anchorAt = if ($state.anchor) { Resolve-HeartbeatAnchor -Anchor ([string]$state.anchor) -Now $nowOffset } else { $null }
        if (-not $anchorAt) {
            # Manual -Now with no anchor: still allow a one-shot service under serial 0
            # so operators can smoke-test without seeding a heartbeat first.
            $serial = 0
        } else {
            $serial = Get-WindowSerial -Anchor $anchorAt -Now $nowOffset
        }
        $result = Invoke-ProjectWindowService -ProjectDir $projectDir -Serial $serial `
            -BatonHome $BatonHome
        if ($Json) {
            ConvertTo-Json -InputObject $result -Depth 8
        } else {
            if ($result.skipped) {
                Write-Output 'window-service: skipped (disabled)'
            } else {
                Write-Output ("window-service: hygiene ok={0}" -f $result.hygiene.ok)
                if ($result.hygiene -and @($result.hygiene.would_remove).Count -gt 0) {
                    Write-Output ("window-service: would remove {0} worktree(s) (not removed)" -f @($result.hygiene.would_remove).Count)
                }
                if ($result.candidates -eq '__disabled__') {
                    Write-Output 'window-service: candidates disabled'
                } elseif ($null -eq $result.candidates) {
                    Write-Output 'window-service: candidates FAILED (briefing still written)'
                } else {
                    Write-Output 'window-service: candidates ok'
                }
                if ($result.briefing) {
                    Write-Output ("window-service: briefing {0} ({1} bytes{2})" -f `
                        $result.briefing.path, $result.briefing.bytes,
                        $(if ($result.briefing.truncated) { ', truncated' } else { '' }))
                } else {
                    Write-Output 'window-service: briefing FAILED'
                }
                if (@($result.failures).Count -gt 0) {
                    Write-Output ("window-service: failures — {0}" -f ($result.failures -join ', '))
                }
            }
        }
    }
    exit 0
} catch {
    Write-WsErr ("window-service: {0}" -f $_.Exception.Message)
    exit 2
}
