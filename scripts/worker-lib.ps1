#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Worker Adapter (Sprint 6). Wraps a fleet dispatch with auto-metering and
  rate-limit -> Usage-Governor state mapping for adapter-backed workers
  (v1: gh models). Advisory only — never blocks a dispatch.
.DESCRIPTION
  See docs/superpowers/specs/2026-06-20-worker-adapter-sprint6-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # Get-FleetProvider, Read-Fleet, Invoke-Fleet
. "$PSScriptRoot/usage-lib.ps1"   # Add-UsageTick, Set-Worker*, Get-WorkerState, forecast

function Get-RateLimitState {
    <# Pure parse of dispatch output+exit into a Usage-Governor state.
       Returns @{state; until; reason}. Fail-open: ambiguous -> available. #>
    param([string]$Output, [int]$ExitCode = 0)
    $result = @{ state = 'available'; until = $null; reason = $null }
    $text = [string]$Output
    if ([string]::IsNullOrWhiteSpace($text)) { return $result }
    $low = $text.ToLowerInvariant()
    $isLimit = ($low -match '\b429\b') -or ($low -match 'rate.?limit') -or ($low -match 'quota') -or
               ($low -match 'too many requests') -or ($low -match 'ratelimitreached')
    if (-not $isLimit) { return $result }
    $result.reason = 'rate limit'
    # Relative retry hint: "try again in 60 seconds", "retry after 5 minutes", "wait 2 hours"
    if ($low -match '(?:try again in|retry after|again in|wait)\s+(\d+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b') {
        $n = [int]$matches[1]
        $u = $matches[2].Substring(0,1)
        $unit = switch ($u) { 's' { 's' } 'm' { 'm' } 'h' { 'h' } default { 's' } }
        $result.state = 'cooling_down'; $result.until = "+$n$unit"; return $result
    }
    # Absolute reset timestamp: "resets at 2026-06-20T05:00:00Z" / "reset: 2026-06-20 05:00"
    if ($text -match '(?:reset[s]?\s*(?:at|:)?\s*)(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?)') {
        $result.state = 'waiting_for_reset'; $result.until = $matches[1].Replace(' ', 'T'); return $result
    }
    $result.state = 'limited'
    return $result
}

function Test-WorkerApiHit {
    <# Did this dispatch consume the allotment? Success OR a detected rate-limit. #>
    param([int]$ExitCode, [hashtable]$LimitState)
    if ($LimitState -and $LimitState.state -ne 'available') { return $true }
    return ($ExitCode -eq 0)
}
