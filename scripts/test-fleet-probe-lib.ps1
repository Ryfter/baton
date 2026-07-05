#!/usr/bin/env pwsh
# Tests for scripts/fleet-probe-lib.ps1 — canary classifier, reachability, live probe.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-probe-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# --- Test-FleetCanary (pure) ---
$c1 = Test-FleetCanary -Output 'PONG' -ExitCode 0 -TimedOut $false
Assert "canary: exact token -> live_ok"        ($c1.live -eq 'live_ok' -and $null -eq $c1.reason)
$c2 = Test-FleetCanary -Output 'the answer is pong.' -ExitCode 0 -TimedOut $false
Assert "canary: case-insensitive substring -> live_ok" ($c2.live -eq 'live_ok')
$c3 = Test-FleetCanary -Output 'usage: codex [options]' -ExitCode 0 -TimedOut $false
Assert "canary: exit 0 but no token -> no-canary" ($c3.live -eq 'live_fail' -and $c3.reason -eq 'no-canary')
$c4 = Test-FleetCanary -Output 'PONG' -ExitCode 3 -TimedOut $false
Assert "canary: nonzero exit beats token -> nonzero-exit" ($c4.live -eq 'live_fail' -and $c4.reason -eq 'nonzero-exit')
$c5 = Test-FleetCanary -Output '' -ExitCode 0 -TimedOut $true
Assert "canary: timeout beats all -> timeout" ($c5.live -eq 'live_fail' -and $c5.reason -eq 'timeout')

# --- Test-ProviderReachable ---
$cliOk = Test-ProviderReachable -Provider @{ name='p'; kind='cli'; command_template='pwsh -NoProfile -Command "x"' }
Assert "reachable: pwsh on PATH -> reachable" ($cliOk.reachable -eq $true -and $null -eq $cliOk.reason)
$cliNo = Test-ProviderReachable -Provider @{ name='p'; kind='cli'; command_template='definitely-not-a-real-binary-xyz foo' }
Assert "reachable: missing binary -> not-on-PATH" ($cliNo.reachable -eq $false -and $cliNo.reason -eq 'not-on-PATH')
$httpOk = Test-ProviderReachable -Provider @{ name='h'; kind='http'; base_url='http://x' } -UrlProbe { param($u) $true }
Assert "reachable: http probe true -> reachable" ($httpOk.reachable -eq $true)
$httpNo = Test-ProviderReachable -Provider @{ name='h'; kind='http'; base_url='http://x' } -UrlProbe { param($u) $false }
Assert "reachable: http probe false -> unreachable" ($httpNo.reachable -eq $false -and $httpNo.reason -eq 'unreachable')

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
