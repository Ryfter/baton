#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$script:fail = 0
function Check($name,$condition){ if($condition){Write-Host "PASS: $name"} else {Write-Host "FAIL: $name"; $script:fail++} }

$libraryPath = Join-Path $PSScriptRoot 'usage-probe-lib.ps1'
Check 'P0 usage probe library exists' (Test-Path -LiteralPath $libraryPath)
if (-not (Test-Path -LiteralPath $libraryPath)) {
    Write-Host "`n$($script:fail) FAILED"
    exit 1
}
. $libraryPath

$requiredFunctions = @(
    'Get-BatonPluginVersion',
    'Invoke-CodexRateLimitTransport',
    'ConvertFrom-CodexRateLimitResponse',
    'Add-UsageProbeCacheRow',
    'Get-FreshUsageProbeCache',
    'Get-CodexUsageProbe'
)
foreach ($functionName in $requiredFunctions) {
    Check "P0 function $functionName exists" ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue))
}
if ($script:fail -gt 0) {
    Write-Host "`n$($script:fail) FAILED"
    exit 1
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("usage-probe-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$savedBatonHome = $env:BATON_HOME
$env:BATON_HOME = $tmp
$T0 = [datetimeoffset]::Parse('2026-07-16T12:00:00-06:00')

function New-SyntheticRateLimitResponse {
    param(
        [Nullable[double]]$FiveHourUsed = 12.5,
        [Nullable[double]]$WeeklyUsed = 34.5,
        [Nullable[long]]$FiveHourReset,
        [Nullable[long]]$WeeklyReset,
        [switch]$NoSecondary
    )
    if ($null -eq $FiveHourReset) { $FiveHourReset = $T0.AddHours(2).ToUnixTimeSeconds() }
    if ($null -eq $WeeklyReset) { $WeeklyReset = $T0.AddDays(2).ToUnixTimeSeconds() }
    $secondary = if ($NoSecondary) { $null } else {
        [pscustomobject]@{
            usedPercent = $WeeklyUsed
            windowDurationMins = 10080
            resetsAt = $WeeklyReset
        }
    }
    return [pscustomobject]@{
        jsonrpc = '2.0'
        id = 2
        result = [pscustomobject]@{
            rateLimits = [pscustomobject]@{
                limitId = 'synthetic-limit'
                limitName = 'synthetic-limit'
                primary = [pscustomobject]@{
                    usedPercent = $FiveHourUsed
                    windowDurationMins = 300
                    resetsAt = $FiveHourReset
                }
                secondary = $secondary
                credits = $null
                individualLimit = $null
                planType = $null
                rateLimitReachedType = $null
            }
            rateLimitResetCredits = [pscustomobject]@{
                availableCount = 0
                credits = @()
            }
        }
    }
}

try {
    $manifestVersion = Get-BatonPluginVersion
    Check 'P1 plugin version is read from the manifest' ($manifestVersion -match '^\d+\.\d+\.\d+')

    $response = New-SyntheticRateLimitResponse
    $observations = ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' -Response $response -ObservedAt $T0 -TtlSeconds 600
    Check 'P2 valid response normalizes two windows' (@($observations).Count -eq 2)
    $fiveHour = $observations | Where-Object { $_.scope -eq 'five_hour' }
    $weekly = $observations | Where-Object { $_.scope -eq 'weekly' }
    Check 'P3 five-hour observation has normalized fields' (
        $fiveHour.worker -eq 'worker-probe' -and
        [double]$fiveHour.used_pct -eq 12.5 -and
        $fiveHour.source -eq 'app_server_probe' -and
        [int]$fiveHour.ttl -eq 600 -and
        [double]$fiveHour.confidence -gt 0)
    Check 'P4 weekly observation maps duration 10080' ($weekly -and [double]$weekly.used_pct -eq 34.5)
    Check 'P5 epoch seconds convert with an explicit offset' (
        [datetimeoffset]::Parse([string]$fiveHour.reset_at).ToUnixTimeSeconds() -eq $T0.AddHours(2).ToUnixTimeSeconds() -and
        [string]$fiveHour.reset_at -match '(Z|[+-]\d\d:\d\d)$')
    Check 'P6 observed_at preserves the supplied instant' (
        [datetimeoffset]::Parse([string]$fiveHour.observed_at).ToUnixTimeSeconds() -eq $T0.ToUnixTimeSeconds())

    $primaryOnly = ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' `
        -Response (New-SyntheticRateLimitResponse -NoSecondary) -ObservedAt $T0 -TtlSeconds 600
    Check 'P7 nullable secondary yields one valid observation' (@($primaryOnly).Count -eq 1 -and $primaryOnly[0].scope -eq 'five_hour')

    $invalidEpoch = New-SyntheticRateLimitResponse -FiveHourReset 1780000000000
    $invalidEpoch.result.rateLimits.secondary = $null
    Check 'P8 millisecond-looking resetsAt is rejected, never reinterpreted' (
        $null -eq (ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' -Response $invalidEpoch -ObservedAt $T0 -TtlSeconds 600))

    $invalidPercent = New-SyntheticRateLimitResponse -FiveHourUsed 101 -NoSecondary
    Check 'P9 out-of-range used percent is rejected' (
        $null -eq (ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' -Response $invalidPercent -ObservedAt $T0 -TtlSeconds 600))

    $wrongId = New-SyntheticRateLimitResponse
    $wrongId.id = 9
    Check 'P10 wrong response id is rejected' (
        $null -eq (ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' -Response $wrongId -ObservedAt $T0 -TtlSeconds 600))

    $cache = Join-Path $tmp 'usage-probe-cache.jsonl'
    Add-UsageProbeCacheRow -Worker 'worker-probe' -Raw $response -Observations $observations `
        -CachePath $cache -ObservedAt $T0 -TtlSeconds 600
    $cachedFresh = Get-FreshUsageProbeCache -Worker 'worker-probe' -CachePath $cache -Now $T0.AddMinutes(9)
    Check 'C1 successful raw response is cached' (
        $cachedFresh -and $cachedFresh.raw.result.rateLimits.primary.windowDurationMins -eq 300)
    Check 'C2 cached observations round-trip as an array' (@($cachedFresh.observations).Count -eq 2)
    Check 'C3 cache expires at ttl' ($null -eq (Get-FreshUsageProbeCache -Worker 'worker-probe' -CachePath $cache -Now $T0.AddMinutes(11)))
    Add-Content -LiteralPath $cache -Encoding utf8NoBOM -Value 'not json'
    Check 'C4 malformed cache row is skipped' ($null -ne (Get-FreshUsageProbeCache -Worker 'worker-probe' -CachePath $cache -Now $T0.AddMinutes(9)))

    $probeCache = Join-Path $tmp 'probe-through-function.jsonl'
    $transportState = @{ calls = 0; version = ''; timeout = 0 }
    $transport = {
        param($clientVersion, $timeoutSeconds)
        $transportState.calls++
        $transportState.version = [string]$clientVersion
        $transportState.timeout = [int]$timeoutSeconds
        return (New-SyntheticRateLimitResponse)
    }.GetNewClosure()
    $snapshot = Get-CodexUsageProbe -Worker 'worker-probe' -Transport $transport `
        -CachePath $probeCache -Now $T0 -TimeoutSeconds 20 -TtlSeconds 600
    Check 'G1 injected transport returns a normalized snapshot' ($snapshot -and @($snapshot.observations).Count -eq 2)
    Check 'G2 transport receives plugin version and 20-second timeout' (
        $transportState.calls -eq 1 -and $transportState.version -eq $manifestVersion -and $transportState.timeout -eq 20)
    Check 'G3 Get-CodexUsageProbe always caches successful raw response' (Test-Path -LiteralPath $probeCache)

    $freshTransportCalls = 0
    $freshSnapshot = Get-CodexUsageProbe -Worker 'worker-probe' -Transport {
        param($clientVersion, $timeoutSeconds)
        $script:freshTransportCalls++
        throw 'fresh cache should prevent transport'
    } -CachePath $probeCache -Now $T0.AddMinutes(5) -TtlSeconds 600
    Check 'G4 fresh cache is reused without a transport call' ($freshSnapshot -and $freshTransportCalls -eq 0)

    $staleCalls = 0
    $staleSnapshot = Get-CodexUsageProbe -Worker 'worker-probe' -Transport {
        param($clientVersion, $timeoutSeconds)
        $script:staleCalls++
        return (New-SyntheticRateLimitResponse -FiveHourUsed 22.5)
    } -CachePath $probeCache -Now $T0.AddMinutes(11) -TtlSeconds 600
    Check 'G5 stale cache re-probes exactly once' ($staleSnapshot -and $staleCalls -eq 1)
    Check 'G6 stale cache refresh returns new observation' (
        [double](($staleSnapshot.observations | Where-Object { $_.scope -eq 'five_hour' }).used_pct) -eq 22.5)

    $failureCases = @(
        @{ name = 'timeout'; transport = { param($clientVersion, $timeoutSeconds) throw 'probe timed out' } },
        @{ name = 'missing binary'; transport = { param($clientVersion, $timeoutSeconds) throw 'codex executable not found' } },
        @{ name = 'garbage'; transport = { param($clientVersion, $timeoutSeconds) return 'not json rpc' } },
        @{ name = 'rpc error'; transport = { param($clientVersion, $timeoutSeconds) return [pscustomobject]@{ jsonrpc='2.0'; id=2; error=[pscustomobject]@{ code=-1; message='synthetic' } } } }
    )
    foreach ($failureCase in $failureCases) {
        $failureCache = Join-Path $tmp ("failure-{0}.jsonl" -f ($failureCase.name -replace ' ', '-'))
        $failureResult = Get-CodexUsageProbe -Worker 'worker-probe' -Transport $failureCase.transport `
            -CachePath $failureCache -Now $T0 -TtlSeconds 600
        Check ("G fail-open: {0} returns null" -f $failureCase.name) ($null -eq $failureResult)
        Check ("G fail-open: {0} does not create a cache row" -f $failureCase.name) (-not (Test-Path -LiteralPath $failureCache))
    }
} finally {
    $env:BATON_HOME = $savedBatonHome
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED"; exit 1 }
Write-Host "`nALL PASS"; exit 0
