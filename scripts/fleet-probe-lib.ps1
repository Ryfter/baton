#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet round-trip probe (Slice 1). Sends a canary prompt to an enabled provider
  and classifies whether it actually answered. Judge-free: a deterministic token.
.NOTES
  Pure classifier (Test-FleetCanary) + reachability (Test-ProviderReachable) +
  live round-trip (Invoke-FleetProbe, added in Task 2). Diagnostic only — never
  mutates state, never throws on a provider failure.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # Read-Fleet, Invoke-Fleet, Get-FleetProvider

$script:FleetCanaryPrompt = 'Reply with exactly the word PONG and nothing else.'
$script:FleetCanaryToken  = 'PONG'

function Test-FleetCanary {
    <# Pure. Classify a dispatch result into a live verdict + reason.
       Precedence: timeout > nonzero-exit > token-match. #>
    param(
        [string]$Output,
        [int]$ExitCode = 0,
        [bool]$TimedOut = $false
    )
    if ($TimedOut)        { return @{ live = 'live_fail'; reason = 'timeout' } }
    if ($ExitCode -ne 0)  { return @{ live = 'live_fail'; reason = 'nonzero-exit' } }
    if (([string]$Output).ToUpperInvariant().Contains($script:FleetCanaryToken)) {
        return @{ live = 'live_ok'; reason = $null }
    }
    return @{ live = 'live_fail'; reason = 'no-canary' }
}

function Test-ProviderReachable {
    <# Is the provider's transport up? cli -> binary on PATH; http -> base_url HEAD.
       -UrlProbe injects the reachability check for tests. Returns @{reachable;reason}. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [scriptblock]$UrlProbe
    )
    if (-not $UrlProbe) {
        $UrlProbe = {
            param($url)
            try { Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null; return $true }
            catch { return $false }
        }
    }
    if ($Provider.kind -eq 'cli') {
        $bin = ([string]$Provider.command_template -split '\s+')[0]
        if (Get-Command $bin -ErrorAction SilentlyContinue) { return @{ reachable = $true; reason = $null } }
        return @{ reachable = $false; reason = 'not-on-PATH' }
    }
    if ($Provider.kind -eq 'http') {
        if (& $UrlProbe ([string]$Provider.base_url)) { return @{ reachable = $true; reason = $null } }
        return @{ reachable = $false; reason = 'unreachable' }
    }
    # Unknown kind: treat as unreachable rather than throwing.
    return @{ reachable = $false; reason = 'unreachable' }
}
