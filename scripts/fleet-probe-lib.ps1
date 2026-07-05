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

# The canary battery: 4 trivial challenges. Only PONG's answer appears in the
# prompt text (the instruction-following check); 42/PARIS/COLD do NOT, so a
# template that merely echoes the prompt scores 1/4 and correctly fails.
$script:FleetCanaryChallenges = @(
    @{ ask = 'Reply with the word PONG.';               token = 'PONG'  }
    @{ ask = 'What is 6 times 7?';                       token = '42'    }
    @{ ask = 'What is the capital of France?';           token = 'PARIS' }
    @{ ask = 'What is the opposite of the word HOT?';    token = 'COLD'  }
)

# Combined single-dispatch prompt (one round-trip per provider), built from the
# challenge asks so it stays in sync with the tokens above.
$script:FleetCanaryPrompt = @(
    'Answer all four questions. Reply with one answer per line, each a single word or number, with no other text:'
    for ($n = 0; $n -lt $script:FleetCanaryChallenges.Count; $n++) {
        "$($n + 1). $($script:FleetCanaryChallenges[$n].ask)"
    }
) -join "`n"

function Test-FleetCanary {
    <# Pure. Score a dispatch result against the canary battery.
       Precedence: timeout > nonzero-exit > token score.
       Returns @{ live; reason; score } where score = tokens matched (0..N),
       or $null when timed out / nonzero exit (no clean answer to score). #>
    param(
        [string]$Output,
        [int]$ExitCode = 0,
        [bool]$TimedOut = $false
    )
    $total = $script:FleetCanaryChallenges.Count
    if ($TimedOut)       { return @{ live = 'live_fail'; reason = 'timeout';      score = $null } }
    if ($ExitCode -ne 0) { return @{ live = 'live_fail'; reason = 'nonzero-exit'; score = $null } }
    $up = ([string]$Output).ToUpperInvariant()
    $score = 0
    $missing = @()
    foreach ($ch in $script:FleetCanaryChallenges) {
        if ($up.Contains(([string]$ch.token).ToUpperInvariant())) { $score++ }
        else { $missing += [string]$ch.token }
    }
    if ($score -eq $total) { return @{ live = 'live_ok';   reason = $null;      score = $score } }
    if ($score -eq 0)      { return @{ live = 'live_fail'; reason = 'no-canary'; score = 0 } }
    return @{ live = 'live_fail'; reason = "canary $score/$total (missing: $($missing -join ', '))"; score = $score }
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

function Invoke-FleetProbe {
    <# Per-provider live round-trip. Reachability precheck -> dispatch a canary
       under an enforced timeout -> classify. Diagnostic: never throws. The
       dispatch runs in a Start-ThreadJob so a hung/slow provider is bounded;
       a timed-out native child may linger (best-effort Stop-Job) — acceptable
       for a diagnostic. -Dispatcher injects for tests. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [int]$TimeoutS = 60,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [scriptblock]$Dispatcher,
        [scriptblock]$UrlProbe
    )
    $name = [string]$Provider.name
    $kind = [string]$Provider.kind
    if ($Provider.enabled -ne $true) {
        return @{ name = $name; kind = $kind; enabled = $false; reachable = $null; live = 'skip'; reason = 'disabled'; elapsed_s = $null; score = $null }
    }
    $reach = Test-ProviderReachable -Provider $Provider -UrlProbe $UrlProbe
    if (-not $reach.reachable) {
        return @{ name = $name; kind = $kind; enabled = $true; reachable = $false; live = 'live_fail'; reason = $reach.reason; elapsed_s = $null; score = $null }
    }
    if (-not $Dispatcher) {
        $Dispatcher = {
            param($prov, $fleetPath, $canary, $scriptRoot)
            . (Join-Path $scriptRoot 'fleet-lib.ps1')
            Invoke-Fleet -Name ([string]$prov.name) -Prompt $canary -Path $fleetPath -NoJournal
        }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false; $output = ''; $exit = 0; $errored = $false
    $threadJob = $null
    try {
        $threadJob = Start-ThreadJob -ScriptBlock $Dispatcher -ArgumentList $Provider, $FleetPath, $script:FleetCanaryPrompt, $PSScriptRoot
        $done = Wait-Job -Job $threadJob -Timeout $TimeoutS
        if (-not $done) {
            $timedOut = $true
            Stop-Job -Job $threadJob -ErrorAction SilentlyContinue
        } else {
            $disp = Receive-Job -Job $threadJob -ErrorAction Stop
            $output = [string]$disp.stdout
            $exit = [int]$disp.exit_code
        }
    } catch {
        $errored = $true
    } finally {
        if ($threadJob) { Remove-Job -Job $threadJob -Force -ErrorAction SilentlyContinue }
        $sw.Stop()
    }
    $elapsed = [int]$sw.Elapsed.TotalSeconds
    if ($errored) {
        return @{ name = $name; kind = $kind; enabled = $true; reachable = $true; live = 'live_fail'; reason = 'dispatch-error'; elapsed_s = $elapsed; score = $null }
    }
    $verdict = Test-FleetCanary -Output $output -ExitCode $exit -TimedOut $timedOut
    return @{ name = $name; kind = $kind; enabled = $true; reachable = $true; live = $verdict.live; reason = $verdict.reason; elapsed_s = $elapsed; score = $verdict.score }
}
