#!/usr/bin/env pwsh
# Tests for scripts/fleet-probe-lib.ps1 — canary classifier, reachability, live probe.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-probe-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# --- Test-FleetCanary (battery) ---
$c1 = Test-FleetCanary -Output 'PONG 42 PARIS COLD' -ExitCode 0 -TimedOut $false
Assert "canary: all 4 tokens -> live_ok score 4" ($c1.live -eq 'live_ok' -and $c1.score -eq 4)
$c2 = Test-FleetCanary -Output 'the answer is pong, 42, paris, and cold' -ExitCode 0 -TimedOut $false
Assert "canary: case-insensitive all 4 -> live_ok" ($c2.live -eq 'live_ok')
$c3 = Test-FleetCanary -Output 'PONG 42' -ExitCode 0 -TimedOut $false
Assert "canary: partial 2/4 -> live_fail with score+missing" ($c3.live -eq 'live_fail' -and $c3.score -eq 2 -and $c3.reason -match 'canary 2/4' -and $c3.reason -match 'PARIS' -and $c3.reason -match 'COLD')
$c4 = Test-FleetCanary -Output 'usage: codex [options]' -ExitCode 0 -TimedOut $false
Assert "canary: zero tokens -> no-canary score 0" ($c4.live -eq 'live_fail' -and $c4.reason -eq 'no-canary' -and $c4.score -eq 0)
$c5 = Test-FleetCanary -Output 'PONG 42 PARIS COLD' -ExitCode 3 -TimedOut $false
Assert "canary: nonzero exit beats full score -> nonzero-exit" ($c5.live -eq 'live_fail' -and $c5.reason -eq 'nonzero-exit')
$c6 = Test-FleetCanary -Output '' -ExitCode 0 -TimedOut $true
Assert "canary: timeout beats all -> timeout" ($c6.live -eq 'live_fail' -and $c6.reason -eq 'timeout')

# --- Test-ProviderReachable ---
$cliOk = Test-ProviderReachable -Provider @{ name='p'; kind='cli'; command_template='pwsh -NoProfile -Command "x"' }
Assert "reachable: pwsh on PATH -> reachable" ($cliOk.reachable -eq $true -and $null -eq $cliOk.reason)
$cliNo = Test-ProviderReachable -Provider @{ name='p'; kind='cli'; command_template='definitely-not-a-real-binary-xyz foo' }
Assert "reachable: missing binary -> not-on-PATH" ($cliNo.reachable -eq $false -and $cliNo.reason -eq 'not-on-PATH')
$httpOk = Test-ProviderReachable -Provider @{ name='h'; kind='http'; base_url='http://x' } -UrlProbe { param($u) $true }
Assert "reachable: http probe true -> reachable" ($httpOk.reachable -eq $true)
$httpNo = Test-ProviderReachable -Provider @{ name='h'; kind='http'; base_url='http://x' } -UrlProbe { param($u) $false }
Assert "reachable: http probe false -> unreachable" ($httpNo.reachable -eq $false -and $httpNo.reason -eq 'unreachable')

# --- Invoke-FleetProbe (live round-trip) ---
# Fake dispatchers returning the Invoke-Fleet shape @{stdout;exit_code}.
$okDisp    = { param($prov,$fp,$canary,$root) @{ stdout = 'PONG 42 PARIS COLD'; exit_code = 0 } }
$partDisp  = { param($prov,$fp,$canary,$root) @{ stdout = 'PONG 42'; exit_code = 0 } }
$noTokDisp = { param($prov,$fp,$canary,$root) @{ stdout = 'help text here'; exit_code = 0 } }
$failDisp  = { param($prov,$fp,$canary,$root) @{ stdout = ''; exit_code = 7 } }
$slowDisp  = { param($prov,$fp,$canary,$root) Start-Sleep -Seconds 5; @{ stdout = 'PONG'; exit_code = 0 } }
$throwDisp = { param($prov,$fp,$canary,$root) throw 'boom' }

$enabledCli = @{ name='w'; kind='cli'; enabled=$true; command_template='pwsh -NoProfile -Command "x"' }

$rSkip = Invoke-FleetProbe -Provider @{ name='d'; kind='cli'; enabled=$false; command_template='pwsh x' }
Assert "probe: disabled -> skip"        ($rSkip.live -eq 'skip' -and $rSkip.reason -eq 'disabled')

$rOk = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $okDisp
Assert "probe: token -> live_ok"        ($rOk.live -eq 'live_ok' -and $rOk.reachable -eq $true)
Assert "probe: live_ok records elapsed" ($rOk.elapsed_s -ge 0)
Assert "probe: full battery -> live_ok"        ($rOk.live -eq 'live_ok' -and $rOk.score -eq 4)

$rPart = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $partDisp
Assert "probe: partial battery -> live_fail 2/4" ($rPart.live -eq 'live_fail' -and $rPart.score -eq 2 -and $rPart.reason -match '2/4')

$rNo = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $noTokDisp
Assert "probe: no token -> no-canary"   ($rNo.live -eq 'live_fail' -and $rNo.reason -eq 'no-canary')
Assert "probe: no tokens -> no-canary"          ($rNo.reason -eq 'no-canary' -and $rNo.score -eq 0)

$rFail = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $failDisp
Assert "probe: nonzero exit -> nonzero-exit" ($rFail.reason -eq 'nonzero-exit')

$rSlow = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $slowDisp -TimeoutS 1
Assert "probe: slow dispatch -> timeout" ($rSlow.reason -eq 'timeout')

$rThrow = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $throwDisp
Assert "probe: throwing dispatch -> dispatch-error" ($rThrow.reason -eq 'dispatch-error')

$rUnreach = Invoke-FleetProbe -Provider @{ name='h'; kind='http'; enabled=$true; base_url='http://x' } -UrlProbe { param($u) $false }
Assert "probe: http down -> unreachable (no dispatch)" ($rUnreach.live -eq 'live_fail' -and $rUnreach.reason -eq 'unreachable')

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
