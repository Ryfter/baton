#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$script:fail = 0
function Check($name,$condition){ if($condition){Write-Host "PASS: $name"} else {Write-Host "FAIL: $name"; $script:fail++} }
function Copy-TestMap($sourceMap) {
    $copy = [ordered]@{}
    foreach ($mapKey in $sourceMap.Keys) { $copy[$mapKey] = $sourceMap[$mapKey] }
    return $copy
}

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
    'Get-ProbeObjectField',
    'Resolve-CodexBarBinaryPath',
    'Invoke-CodexBarUsageProcess',
    'Invoke-CodexBarUsageTransport',
    'ConvertTo-CodexBarObservation',
    'ConvertFrom-CodexBarUsageResponse',
    'Test-UsageProbeTransportRequirement',
    'Add-UsageProbeCacheRow',
    'Get-FreshUsageProbeCache',
    'Get-CodexUsageProbe',
    'Get-UsageProbeTransport',
    'Get-UsageProbeTransportName',
    'Resolve-UsageProbeTransportName',
    'Test-UsageProbeEligible',
    'Get-ProviderUsageProbe',
    'Get-UsageProbeCapDecision',
    'Get-FleetMedianDispatchTokens',
    'Get-UsageFitAdvisory',
    'Get-MonthlyUsagePaceAdvisory',
    'Test-UsageSurplusSpend',
    'Add-UsageProbeLimitedRows',
    'Add-UsagePreflightEvent'
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

    # ---- transport registry: eligibility resolves BY NAME, not by platform (#173) ----
    $codexPair = Get-UsageProbeTransport -Name 'codex-rate-limit'
    Check 'R0 registry exposes codex-rate-limit as an invoke+parse pair' (
        (Get-UsageProbeTransportName) -contains 'codex-rate-limit' -and
        $null -ne $codexPair -and $codexPair.invoke -is [scriptblock] -and $codexPair.parse -is [scriptblock])
    Check 'R0 an unregistered name looks up to nothing' (
        ($null -eq (Get-UsageProbeTransport -Name 'transport-not-registered')) -and
        ($null -eq (Get-UsageProbeTransport -Name '')))

    $explicitRow = @{
        name = 'worker-explicit'; kind = 'cli'; platform = 'platform-a'
        usage_policy = @{ probe = $true; probe_transport = 'codex-rate-limit'
                          soft_cap_5h = [double]75; soft_cap_weekly = [double]85 }
    }
    Check 'R1 explicit probe_transport resolves by name, whatever the platform is' (
        (Resolve-UsageProbeTransportName -Provider $explicitRow) -eq 'codex-rate-limit' -and
        (Test-UsageProbeEligible -Provider $explicitRow))

    # BACK-COMPAT: this is the shape of the operator's live fleet.yaml row — it
    # declares no transport, and it must keep probing without any config edit.
    $legacyRow = @{
        name = 'worker-legacy'; kind = 'cli'; platform = 'codex'
        usage_policy = @{ probe = $true; soft_cap_5h = [double]75; soft_cap_weekly = [double]85 }
    }
    Check 'R2 back-compat: cli+codex with NO probe_transport still resolves codex-rate-limit' (
        (Resolve-UsageProbeTransportName -Provider $legacyRow) -eq 'codex-rate-limit' -and
        (Test-UsageProbeEligible -Provider $legacyRow))

    # Fail closed: an unrecognized transport is "no probe", never a speculative attempt.
    $unknownRow = @{
        name = 'worker-unknown'; kind = 'cli'; platform = 'platform-a'
        usage_policy = @{ probe = $true; probe_transport = 'transport-not-registered' }
    }
    $unknownState = @{ calls = 0 }
    $unknownCache = Join-Path $tmp 'registry-unknown.jsonl'
    $unknownProbe = Get-ProviderUsageProbe -Worker 'worker-unknown' -Provider $unknownRow -Transport {
        param($clientVersion, $timeoutSeconds)
        $unknownState.calls++
        return (New-SyntheticRateLimitResponse)
    }.GetNewClosure() -CachePath $unknownCache -Now $T0 -TtlSeconds 600
    Check 'R3 unknown probe_transport resolves to nothing, probes nothing, throws nothing' (
        ($null -eq (Resolve-UsageProbeTransportName -Provider $unknownRow)) -and
        (-not (Test-UsageProbeEligible -Provider $unknownRow)) -and
        ($null -eq $unknownProbe) -and $unknownState.calls -eq 0 -and
        (-not (Test-Path -LiteralPath $unknownCache)))

    $nonCodexRow = @{
        name = 'worker-other'; kind = 'cli'; platform = 'platform-a'
        usage_policy = @{ probe = $true; soft_cap_5h = [double]75 }
    }
    $nonCodexState = @{ calls = 0 }
    $nonCodexCache = Join-Path $tmp 'registry-non-codex.jsonl'
    $nonCodexProbe = Get-ProviderUsageProbe -Worker 'worker-other' -Provider $nonCodexRow -Transport {
        param($clientVersion, $timeoutSeconds)
        $nonCodexState.calls++
        return (New-SyntheticRateLimitResponse)
    }.GetNewClosure() -CachePath $nonCodexCache -Now $T0 -TtlSeconds 600
    Check 'R4 absent probe_transport on a non-codex row means no transport and no probe' (
        ($null -eq (Resolve-UsageProbeTransportName -Provider $nonCodexRow)) -and
        ($null -eq $nonCodexProbe) -and $nonCodexState.calls -eq 0 -and
        (-not (Test-Path -LiteralPath $nonCodexCache)))

    $probeOffRow = @{
        name = 'worker-off'; kind = 'cli'; platform = 'codex'
        usage_policy = @{ probe = $false; soft_cap_5h = [double]75 }
    }
    Check 'R5 probe false is ineligible even though a transport resolves' (
        (Resolve-UsageProbeTransportName -Provider $probeOffRow) -eq 'codex-rate-limit' -and
        (-not (Test-UsageProbeEligible -Provider $probeOffRow)))
    $noPolicyRow = @{ name = 'worker-nopolicy'; kind = 'cli'; platform = 'codex' }
    Check 'R5 a row with no usage_policy resolves nothing and is ineligible' (
        ($null -eq (Resolve-UsageProbeTransportName -Provider $noPolicyRow)) -and
        (-not (Test-UsageProbeEligible -Provider $noPolicyRow)) -and
        (-not (Test-UsageProbeEligible -Provider $null)))

    $shapeTransport = { param($clientVersion, $timeoutSeconds) return (New-SyntheticRateLimitResponse) }
    $codexShape = Get-CodexUsageProbe -Worker 'worker-shape' -Transport $shapeTransport `
        -CachePath (Join-Path $tmp 'shape-codex.jsonl') -Now $T0 -TimeoutSeconds 20 -TtlSeconds 600
    $genericShape = Get-ProviderUsageProbe -Worker 'worker-shape' -Provider $legacyRow -Transport $shapeTransport `
        -CachePath (Join-Path $tmp 'shape-generic.jsonl') -Now $T0 -TimeoutSeconds 20 -TtlSeconds 600
    Check 'R6 generic entry returns the same snapshot shape as Get-CodexUsageProbe' (
        $null -ne $codexShape -and $null -ne $genericShape -and
        ((@($genericShape.Keys) -join ',') -eq (@($codexShape.Keys) -join ',')) -and
        (@($genericShape.observations).Count -eq @($codexShape.observations).Count) -and
        ([string]$genericShape.observed_at -eq [string]$codexShape.observed_at) -and
        ([int]$genericShape.ttl -eq [int]$codexShape.ttl) -and
        ($genericShape.cached -eq $codexShape.cached) -and
        ([double](($genericShape.observations | Where-Object { $_.scope -eq 'five_hour' }).used_pct) -eq
         [double](($codexShape.observations | Where-Object { $_.scope -eq 'five_hour' }).used_pct)))

    $badNameState = @{ calls = 0 }
    $badNameCache = Join-Path $tmp 'registry-bad-name.jsonl'
    $badNameProbe = Get-ProviderUsageProbe -Worker 'worker-legacy' -TransportName 'transport-not-registered' -Transport {
        param($clientVersion, $timeoutSeconds)
        $badNameState.calls++
        return (New-SyntheticRateLimitResponse)
    }.GetNewClosure() -CachePath $badNameCache -Now $T0 -TtlSeconds 600
    Check 'R7 an explicit unregistered TransportName probes nothing' (
        ($null -eq $badNameProbe) -and $badNameState.calls -eq 0 -and (-not (Test-Path -LiteralPath $badNameCache)))

    # ---- policy caps + structured advisory rows ----
    $policyProvider = @{
        name = 'worker-probe'; kind = 'cli'; platform = 'codex'; cost_tier = 'paid'
        usage_policy = @{ probe = $true; soft_cap_5h = [double]75; soft_cap_weekly = [double]85; monthly_allowance = [double]100 }
    }
    $underResponse = New-SyntheticRateLimitResponse -FiveHourUsed 74.9 -WeeklyUsed 84.9
    $underObs = ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' -Response $underResponse -ObservedAt $T0 -TtlSeconds 600
    $underDecision = Get-UsageProbeCapDecision -Provider $policyProvider -Observations @($underObs)
    Check 'D1 observations under both caps are not held' (-not $underDecision.over_cap -and @($underDecision.windows).Count -eq 0)
    Check 'D1b under-cap decision retains checked-window evidence' (@($underDecision.checked).Count -eq 2)

    $fiveCapResponse = New-SyntheticRateLimitResponse -FiveHourUsed 75 -WeeklyUsed 20
    $fiveCapObs = ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' -Response $fiveCapResponse -ObservedAt $T0 -TtlSeconds 600
    $fiveCapDecision = Get-UsageProbeCapDecision -Provider $policyProvider -Observations @($fiveCapObs)
    Check 'D2 five-hour equality reaches the cap' ($fiveCapDecision.over_cap -and @($fiveCapDecision.windows).Count -eq 1)
    Check 'D3 five-hour decision names window, value, cap, and knob' (
        $fiveCapDecision.windows[0].window -eq 'five_hour' -and
        [double]$fiveCapDecision.windows[0].used_pct -eq 75 -and
        [double]$fiveCapDecision.windows[0].cap -eq 75 -and
        $fiveCapDecision.windows[0].policy_knob -eq 'soft_cap_5h')

    $weeklyCapResponse = New-SyntheticRateLimitResponse -FiveHourUsed 10 -WeeklyUsed 90
    $weeklyCapObs = ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' -Response $weeklyCapResponse -ObservedAt $T0 -TtlSeconds 600
    $weeklyCapDecision = Get-UsageProbeCapDecision -Provider $policyProvider -Observations @($weeklyCapObs)
    Check 'D4 weekly cap is independent' (
        $weeklyCapDecision.over_cap -and
        $weeklyCapDecision.windows[0].window -eq 'weekly' -and
        $weeklyCapDecision.windows[0].policy_knob -eq 'soft_cap_weekly')

    $bothCapResponse = New-SyntheticRateLimitResponse -FiveHourUsed 80 -WeeklyUsed 90
    $bothCapObs = ConvertFrom-CodexRateLimitResponse -Worker 'worker-probe' -Response $bothCapResponse -ObservedAt $T0 -TtlSeconds 600
    $bothCapDecision = Get-UsageProbeCapDecision -Provider $policyProvider -Observations @($bothCapObs)
    Check 'D5 both cap crossings remain in one decision' ($bothCapDecision.over_cap -and @($bothCapDecision.windows).Count -eq 2)

    $policyUsage = Join-Path $tmp 'policy-usage.jsonl'
    Add-UsageProbeLimitedRows -Worker 'worker-probe' -Decision $underDecision -UsagePath $policyUsage
    Check 'J1 under-cap observations never journal limited state' (-not (Test-Path -LiteralPath $policyUsage))
    Add-UsageProbeLimitedRows -Worker 'worker-probe' -Decision $fiveCapDecision -UsagePath $policyUsage
    $limitedRows = @(Get-Content -LiteralPath $policyUsage | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'J2 over-cap observation journals one advisory limited row' (
        $limitedRows.Count -eq 1 -and $limitedRows[0].event -eq 'limited' -and $limitedRows[0].source -eq 'app_server_probe')
    Check 'J3 limited row preserves normalized freshness and cap fields' (
        $limitedRows[0].observed_at -and [int]$limitedRows[0].ttl -eq 600 -and
        [double]$limitedRows[0].used_pct -eq 75 -and [double]$limitedRows[0].cap -eq 75 -and
        $limitedRows[0].window -eq 'five_hour')

    Add-UsagePreflightEvent -Worker 'worker-probe' -Outcome 'rerouted' -WindowDecision $fiveCapDecision.windows[0] `
        -Substitute 'worker-peer' -UsagePath $policyUsage -Reason 'soft_cap'
    Add-UsagePreflightEvent -Worker 'worker-probe' -Outcome 'held' -WindowDecision $weeklyCapDecision.windows[0] `
        -UsagePath $policyUsage -Reason 'soft_cap'
    Add-UsagePreflightEvent -Worker 'worker-probe' -Outcome 'dispatched' -UsagePath $policyUsage -Reason 'surplus_spend'
    $preflightRows = @((Get-Content -LiteralPath $policyUsage | ForEach-Object { $_ | ConvertFrom-Json }) | Where-Object { $_.event -eq 'preflight' })
    Check 'J4 preflight rows carry all three outcomes' ((@($preflightRows.outcome | Sort-Object) -join ',') -eq 'dispatched,held,rerouted')
    $rerouteRow = $preflightRows | Where-Object { $_.outcome -eq 'rerouted' }
    Check 'J5 reroute row carries policy evidence and substitute' (
        $rerouteRow.worker -eq 'worker-probe' -and $rerouteRow.substitute -eq 'worker-peer' -and
        [double]$rerouteRow.used_pct -eq 75 -and [double]$rerouteRow.cap -eq 75 -and
        $rerouteRow.window -eq 'five_hour')
    Check 'J6 surplus reason is journaled' (($preflightRows | Where-Object { $_.reason -eq 'surplus_spend' }).outcome -eq 'dispatched')

    # ---- token median + will-this-job-fit advisory ----
    $fleetJournal = Join-Path $tmp 'model-routing-log.md'
    Set-Content -LiteralPath $fleetJournal -Encoding utf8NoBOM -Value @('# Model Routing Log', '# synthetic rows')
    for ($index = 1; $index -le 25; $index++) {
        $providerName = if ($index -eq 5) { 'worker-other' } else { 'worker-probe' }
        Add-Content -LiteralPath $fleetJournal -Encoding utf8NoBOM -Value (
            "2026-07-16T12:{0:D2}:00-06:00 | fleet | {1} | 1s | exit:0 | `"synthetic`" | host:test | tok:{2}(estimate)" -f $index, $providerName, ($index * 100))
    }
    $tokenStats = Get-FleetMedianDispatchTokens -Worker 'worker-probe' -JournalPath $fleetJournal -SampleSize 20
    Check 'T1 token history uses only the latest 20 provider dispatches' ($tokenStats.count -eq 20)
    Check 'T2 even token sample median averages the center values' ([double]$tokenStats.median -eq 1550)
    Check 'T3 token history returns a guarded positive total' ([double]$tokenStats.total -gt 0)

    $tightObservation = [ordered]@{
        worker='worker-probe'; scope='five_hour'; used_pct=[double]98; reset_at=$T0.AddHours(1).ToString('o')
        source='app_server_probe'; observed_at=$T0.ToString('o'); ttl=600; confidence=[double]0.95
    }
    $fitLine = Get-UsageFitAdvisory -Worker 'worker-probe' -Observation $tightObservation -TokenStats $tokenStats
    Check 'T4 fit advisory names usage and median token burn' ($fitLine -match 'worker-probe at 98% of 5h' -and $fitLine -match 'typical dispatch burns ~1550 tok')
    $comfortableObservation = Copy-TestMap $tightObservation; $comfortableObservation.used_pct = [double]20
    Check 'T5 fit advisory stays quiet with ample remaining share' ($null -eq (Get-UsageFitAdvisory -Worker 'worker-probe' -Observation $comfortableObservation -TokenStats $tokenStats))
    Check 'T6 zero token history never divides or advises' (
        $null -eq (Get-UsageFitAdvisory -Worker 'worker-probe' -Observation $tightObservation -TokenStats @{ count=0; median=0; total=0 }))

    # ---- monthly pace is advisory-only and observation-driven ----
    $monthlyRows = @(
        [pscustomobject]@{
            worker='worker-probe'; scope='paid_credit'; source='billing_api'; consumed=[double]60
            observed_at=$T0.ToString('o'); reset_at=$T0.AddDays(20).ToString('o')
        }
    )
    $pace = Get-MonthlyUsagePaceAdvisory -Worker 'worker-probe' -UsagePolicy $policyProvider.usage_policy -Rows $monthlyRows -Now $T0
    Check 'M1 consumed above day-of-cycle pace is advisory' ($pace.advisory -and $pace.line -match 'monthly usage pace')
    Check 'M2 monthly pace reports expected consumption with guarded math' ([double]$pace.consumed -eq 60 -and [double]$pace.expected -gt 0)
    $monthlyRows[0].consumed = [double]10
    $paceUnder = Get-MonthlyUsagePaceAdvisory -Worker 'worker-probe' -UsagePolicy $policyProvider.usage_policy -Rows $monthlyRows -Now $T0
    Check 'M3 consumed under pace is not advisory' (-not $paceUnder.advisory)
    Check 'M4 absent allowance is unavailable, never advisory' (
        (Get-MonthlyUsagePaceAdvisory -Worker 'worker-probe' -UsagePolicy @{} -Rows $monthlyRows -Now $T0).status -eq 'unavailable')
    Check 'M5 missing observation is unavailable, never advisory' (
        (Get-MonthlyUsagePaceAdvisory -Worker 'worker-probe' -UsagePolicy $policyProvider.usage_policy -Rows @() -Now $T0).status -eq 'unavailable')

    # ---- bounded weekly surplus-spend preference ----
    $surplusWeekly = [ordered]@{
        worker='worker-probe'; scope='weekly'; used_pct=[double]40; reset_at=$T0.AddHours(24).ToString('o')
        source='app_server_probe'; observed_at=$T0.ToString('o'); ttl=600; confidence=[double]0.95
    }
    $surplusSnapshot = [ordered]@{ observations=@($surplusWeekly); observed_at=$T0.ToString('o'); ttl=600; cached=$true }
    $surplus = Test-UsageSurplusSpend -Provider $policyProvider -Snapshot $surplusSnapshot -Now $T0.AddMinutes(5)
    Check 'S1 surplus applies at the 24-hour boundary with headroom' ($surplus.apply -and [double]$surplus.preference -gt 0 -and $surplus.reason -eq 'surplus_spend')
    $outsideSnapshot = Copy-TestMap $surplusSnapshot; $outsideWeekly = Copy-TestMap $surplusWeekly; $outsideWeekly.reset_at = $T0.AddHours(24).AddSeconds(1).ToString('o'); $outsideSnapshot.observations = @($outsideWeekly)
    Check 'S2 surplus rejects reset outside 24 hours' (-not (Test-UsageSurplusSpend -Provider $policyProvider -Snapshot $outsideSnapshot -Now $T0).apply)
    $lowHeadroomSnapshot = Copy-TestMap $surplusSnapshot; $lowHeadroomWeekly = Copy-TestMap $surplusWeekly; $lowHeadroomWeekly.used_pct = [double]65; $lowHeadroomSnapshot.observations = @($lowHeadroomWeekly)
    Check 'S3 surplus requires used below weekly cap minus 20' (-not (Test-UsageSurplusSpend -Provider $policyProvider -Snapshot $lowHeadroomSnapshot -Now $T0).apply)
    $httpProvider = $policyProvider.Clone(); $httpProvider.kind = 'http'
    Check 'S4 surplus never applies to an HTTP or metered API tier' (-not (Test-UsageSurplusSpend -Provider $httpProvider -Snapshot $surplusSnapshot -Now $T0).apply)
    $wrongAdapter = $policyProvider.Clone(); $wrongAdapter.platform = 'grok'
    Check 'S5 surplus requires the shipped probe adapter' (-not (Test-UsageSurplusSpend -Provider $wrongAdapter -Snapshot $surplusSnapshot -Now $T0).apply)
    $probeOff = $policyProvider.Clone(); $probeOff.usage_policy = $policyProvider.usage_policy.Clone(); $probeOff.usage_policy.probe = $false
    Check 'S6 surplus requires probe true' (-not (Test-UsageSurplusSpend -Provider $probeOff -Snapshot $surplusSnapshot -Now $T0).apply)
    Check 'S7 stale snapshot never applies surplus preference' (-not (Test-UsageSurplusSpend -Provider $policyProvider -Snapshot $surplusSnapshot -Now $T0.AddMinutes(11)).apply)
    # Preference must stay a near-tie breaker: quality gap 0.05 => score delta 5e-5 >> 1e-7.
    Check 'S8 surplus preference is a true near-tie breaker (<< quality resolution)' (
        [double]$surplus.preference -gt 0 -and [double]$surplus.preference -le 1e-7)

    # ---- multi-window loud line + journal name ALL crossings (FIX 4) ----
    $multiLine = Format-UsagePreflightLine -Worker 'worker-probe' -WindowDecision $bothCapDecision.windows -Outcome held
    Check 'D6 multi-window hold line names every crossed window' (
        $multiLine -match 'five_hour' -and $multiLine -match 'weekly' -and
        $multiLine -match 'soft_cap_5h' -and $multiLine -match 'soft_cap_weekly')
    $multiJournal = Join-Path $tmp 'multi-window-preflight.jsonl'
    Add-UsagePreflightEvent -Worker 'worker-probe' -Outcome 'held' -WindowDecision $bothCapDecision.windows `
        -UsagePath $multiJournal -Reason 'soft_cap'
    $multiRow = (Get-Content -LiteralPath $multiJournal -Raw | ConvertFrom-Json)
    Check 'D6 multi-window journal event names every crossed window' (
        [string]$multiRow.window -match 'five_hour' -and [string]$multiRow.window -match 'weekly')

    # ---- transport process path: stderr drained + child killed on timeout (FIX 5) ----
    # Hermetic fake child: flood stderr then sleep. Never invoke the real codex binary.
    $childPidFile = Join-Path $tmp 'transport-child-pid.txt'
    $stderrFloodStub = @"
Set-Content -LiteralPath '$($childPidFile.Replace("'", "''"))' -Value `$PID -Encoding utf8NoBOM
`$noise = ('E' * 200)
1..2000 | ForEach-Object { [Console]::Error.WriteLine(`$noise) }
Start-Sleep -Seconds 120
"@
    $stubPath = Join-Path $tmp 'stderr-flood-stub.ps1'
    Set-Content -LiteralPath $stubPath -Value $stderrFloodStub -Encoding utf8NoBOM
    $transportStarted = [datetime]::UtcNow
    $transportResult = Invoke-CodexRateLimitTransport -ClientVersion 'test' -TimeoutSeconds 2 `
        -FileName 'pwsh' -ArgumentList @('-NoProfile', '-File', $stubPath)
    $transportElapsed = ([datetime]::UtcNow - $transportStarted).TotalSeconds
    Check 'X1 chatty-stderr timeout returns null (fail-open)' ($null -eq $transportResult)
    Check 'X1 transport returns near the timeout (stderr did not stall the pipe)' (
        $transportElapsed -lt 15 -and $transportElapsed -ge 1.5)
    $childPidText = if (Test-Path -LiteralPath $childPidFile) {
        (Get-Content -LiteralPath $childPidFile -Raw).Trim()
    } else { '' }
    $childPidValue = 0
    $childAlive = $false
    if ([int]::TryParse($childPidText, [ref]$childPidValue) -and $childPidValue -gt 0) {
        $childAlive = $null -ne (Get-Process -Id $childPidValue -ErrorAction SilentlyContinue)
    }
    Check 'X1 timed-out transport child is killed' (-not $childAlive -and $childPidValue -gt 0)

    # =======================================================================
    # codexbar-cli transport (#173, step 2)
    # Every case below is driven by an INJECTED FAKE returning canned JSON.
    # The real binary is never invoked, on any path, in any of these checks.
    # All values are placeholders: no real account, model id, or percentage.
    # =======================================================================
    # Literal JSON text, so a fixture can express values ConvertTo-Json cannot
    # (a "NaN" percent, a non-timestamp resets_at) exactly as the tool would emit.
    function New-SyntheticCodexBarJson {
        param(
            [string]$FiveHourUsed = '11',
            [string]$WeeklyUsed = '42',
            [string]$FiveHourMinutes = '300',
            [string]$WeeklyMinutes = '10080',
            [string]$SourceLabel = 'source-a',
            [string]$FiveHourReset,
            [string]$ExtraWindowsJson
        )
        if ([string]::IsNullOrWhiteSpace($FiveHourReset)) { $FiveHourReset = $T0.AddHours(3).ToUniversalTime().ToString('o') }
        $weeklyReset = $T0.AddDays(3).ToUniversalTime().ToString('o')
        $extraLine = if ([string]::IsNullOrEmpty($ExtraWindowsJson)) { '' } else { ", ""extra_rate_windows"": $ExtraWindowsJson" }
        return (@(
            '[ {',
            "  ""provider"": ""provider-a"", ""source"": ""$SourceLabel"",",
            '  "usage": {',
            "    ""primary"":   { ""window_minutes"": $FiveHourMinutes, ""used_percent"": $FiveHourUsed, ""resets_at"": ""$FiveHourReset"" },",
            "    ""secondary"": { ""window_minutes"": $WeeklyMinutes, ""used_percent"": $WeeklyUsed, ""resets_at"": ""$weeklyReset"" },",
            "    ""updated_at"": ""$($T0.ToUniversalTime().ToString('o'))"" }$extraLine",
            '} ]'
        ) -join "`n")
    }
    function New-SyntheticScopedWindowJson {
        param([string]$Id, [string]$Used, [string]$Minutes = '10080')
        $scopedReset = $T0.AddDays(3).ToUniversalTime().ToString('o')
        return (@(
            "[ { ""id"": ""$Id"", ""title"": ""placeholder scoped window"",",
            "    ""window"": { ""window_minutes"": $Minutes, ""used_percent"": $Used, ""resets_at"": ""$scopedReset"" } } ]"
        ) -join "`n")
    }
    function New-CodexBarFakeRunner {
        param([string]$Stdout, [int]$ExitCode = 0, [hashtable]$State)
        return {
            param($runnerFile, $runnerArguments, $runnerTimeout)
            if ($null -ne $State) {
                $State.calls++
                $State.file = [string]$runnerFile
                $State.arguments = [string[]]@($runnerArguments)
                $State.timeout = [int]$runnerTimeout
            }
            return @{ exit_code = $ExitCode; stdout = $Stdout; stderr = ''; duration_ms = 7 }
        }.GetNewClosure()
    }
    function Get-CodexBarFakeObservation {
        param([string]$Json, [int]$ExitCode = 0, [hashtable]$State, [string]$ProbeProvider = 'provider-a')
        $raw = Invoke-CodexBarUsageTransport -ProbeProvider $ProbeProvider -TimeoutSeconds 20 `
            -Runner (New-CodexBarFakeRunner -Stdout $Json -ExitCode $ExitCode -State $State)
        if ($null -eq $raw) { return $null }
        $parsed = ConvertFrom-CodexBarUsageResponse -Worker 'worker-bar' -Response $raw -ObservedAt $T0 -TtlSeconds 600
        if ($null -eq $parsed) { return $null }
        # Keep a one-row result an ARRAY across the function boundary.
        return ,([object[]]@($parsed))
    }

    $barPair = Get-UsageProbeTransport -Name 'codexbar-cli'
    Check 'B0 registry exposes codexbar-cli as an invoke+parse pair' (
        (Get-UsageProbeTransportName) -contains 'codexbar-cli' -and
        $null -ne $barPair -and $barPair.invoke -is [scriptblock] -and $barPair.parse -is [scriptblock])

    $plainState = @{ calls = 0 }
    $plainObs = Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson) -State $plainState
    Check 'B1 plan-wide JSON normalizes to five_hour + weekly' (
        @($plainObs).Count -eq 2 -and
        (@($plainObs | ForEach-Object { [string]$_.scope } | Sort-Object) -join ',') -eq 'five_hour,weekly')
    $barFiveHour = @($plainObs | Where-Object { [string]$_.scope -eq 'five_hour' })[0]
    $barWeekly = @($plainObs | Where-Object { [string]$_.scope -eq 'weekly' })[0]
    Check 'B2 used_percent, source provenance, ttl and confidence are normalized' (
        [string]$barFiveHour.worker -eq 'worker-bar' -and
        [double]$barFiveHour.used_pct -eq 11 -and [double]$barWeekly.used_pct -eq 42 -and
        [string]$barFiveHour.source -eq 'codexbar:source-a' -and
        [int]$barFiveHour.ttl -eq 600 -and [double]$barFiveHour.confidence -eq 0.9)
    Check 'B3 ISO-8601 resets_at round-trips as UTC (not reinterpreted as an epoch)' (
        [datetimeoffset]::Parse([string]$barFiveHour.reset_at).ToUnixTimeSeconds() -eq $T0.AddHours(3).ToUnixTimeSeconds() -and
        [string]$barFiveHour.reset_at -match '(Z|\+00:00)$')
    Check 'B4 plan-wide observations carry no scope_id' (
        $null -eq $barFiveHour.scope_id -and $null -eq $barWeekly.scope_id)
    Check 'B5 the transport asks the tool for exactly one named provider as JSON' (
        $plainState.calls -eq 1 -and
        (($plainState.arguments -join ' ') -eq 'usage --provider provider-a --json') -and
        $plainState.timeout -eq 20)

    # ---- extra_rate_windows: model-scoped sub-quotas are accounted for ----
    $exhaustedScopeJson = New-SyntheticScopedWindowJson -Id 'scope-window-a' -Used '100'
    $scopedJson = New-SyntheticCodexBarJson -WeeklyUsed '42' -ExtraWindowsJson $exhaustedScopeJson
    $scopedObs = Get-CodexBarFakeObservation -Json $scopedJson
    $scopedRows = @($scopedObs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.scope_id) })
    $planWideWeekly = @($scopedObs | Where-Object { [string]$_.scope -eq 'weekly' -and [string]::IsNullOrWhiteSpace([string]$_.scope_id) })
    Check 'B6 a scoped window is emitted as its own third observation' (
        @($scopedObs).Count -eq 3 -and $scopedRows.Count -eq 1 -and
        [string]$scopedRows[0].scope_id -eq 'scope-window-a' -and
        [string]$scopedRows[0].scope -eq 'weekly' -and [double]$scopedRows[0].used_pct -eq 100)
    Check 'B7 an exhausted scoped window does not move the plan-wide weekly figure' (
        $planWideWeekly.Count -eq 1 -and [double]$planWideWeekly[0].used_pct -eq 42)
    $noExtraObs = Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson)
    Check 'B8 absent extra_rate_windows behaves exactly as before (two plan-wide rows)' (
        @($noExtraObs).Count -eq 2 -and
        @($noExtraObs | Where-Object { $null -ne $_.scope_id }).Count -eq 0)
    $emptyExtraObs = Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson -ExtraWindowsJson '[]')
    Check 'B9 an empty extra_rate_windows array is normal, not an error' (@($emptyExtraObs).Count -eq 2)
    $idlessObs = Get-CodexBarFakeObservation -Json (
        New-SyntheticCodexBarJson -ExtraWindowsJson (New-SyntheticScopedWindowJson -Id '' -Used '100'))
    Check 'B10 an id-less scoped window is dropped, never mistaken for plan-wide' (
        @($idlessObs).Count -eq 2 -and
        @($idlessObs | Where-Object { [string]$_.scope -eq 'weekly' }).Count -eq 1)

    # ---- malformed input is dropped per window, never coerced ----
    $mixedObs = Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson -FiveHourMinutes '4321')
    Check 'B11 an unknown window_minutes skips that window and keeps the others' (
        @($mixedObs).Count -eq 1 -and [string]$mixedObs[0].scope -eq 'weekly')
    foreach ($badPercent in @('101', '-1', '"NaN"')) {
        $badObs = Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson -FiveHourUsed $badPercent)
        Check ("B12 used_percent {0} is rejected, other windows survive" -f $badPercent) (
            @($badObs).Count -eq 1 -and [string]$badObs[0].scope -eq 'weekly')
    }
    $badResetObs = Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson -FiveHourReset 'not-a-timestamp')
    Check 'B13 an unparseable resets_at rejects the window rather than guessing' (
        @($badResetObs).Count -eq 1 -and [string]$badResetObs[0].scope -eq 'weekly')

    # ---- fail-soft on observation: never throw, always $null ----
    Check 'B14 malformed JSON returns null without throwing' (
        $null -eq (Get-CodexBarFakeObservation -Json '{ not json'))
    $nonZeroState = @{ calls = 0 }
    Check 'B15 a non-zero exit returns null without throwing' (
        ($null -eq (Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson) -ExitCode 3 -State $nonZeroState)) -and
        $nonZeroState.calls -eq 1)
    Check 'B16 an empty array returns null without throwing' (
        $null -eq (Get-CodexBarFakeObservation -Json '[]'))
    Check 'B17 empty stdout returns null without throwing' (
        $null -eq (Get-CodexBarFakeObservation -Json '   '))

    # ---- fail-closed on identity: no probe_provider, nothing runs ----
    $identityState = @{ calls = 0 }
    $identityResult = Invoke-CodexBarUsageTransport -ProbeProvider '' -TimeoutSeconds 20 `
        -Runner (New-CodexBarFakeRunner -Stdout (New-SyntheticCodexBarJson) -State $identityState)
    Check 'B18 FAIL CLOSED: a missing probe_provider launches nothing at all' (
        $null -eq $identityResult -and $identityState.calls -eq 0)
    $badTokenState = @{ calls = 0 }
    $badTokenResult = Invoke-CodexBarUsageTransport -ProbeProvider 'provider a; rm -rf' -TimeoutSeconds 20 `
        -Runner (New-CodexBarFakeRunner -Stdout (New-SyntheticCodexBarJson) -State $badTokenState)
    Check 'B19 a non-token probe_provider is refused before anything is launched' (
        $null -eq $badTokenResult -and $badTokenState.calls -eq 0)

    $noProviderRow = @{
        name = 'worker-bar'; kind = 'cli'; platform = 'platform-b'
        usage_policy = @{ probe = $true; probe_transport = 'codexbar-cli'; soft_cap_weekly = [double]85 }
    }
    Check 'B20 FAIL CLOSED: a codexbar row without probe_provider resolves no transport' (
        ($null -eq (Resolve-UsageProbeTransportName -Provider $noProviderRow)) -and
        (-not (Test-UsageProbeEligible -Provider $noProviderRow)))
    $barRow = @{
        name = 'worker-bar'; kind = 'cli'; platform = 'platform-b'
        usage_policy = @{ probe = $true; probe_transport = 'codexbar-cli'; probe_provider = 'provider-a'
                          soft_cap_5h = [double]75; soft_cap_weekly = [double]85 }
    }
    Check 'B21 a codexbar row WITH probe_provider resolves and is eligible' (
        (Resolve-UsageProbeTransportName -Provider $barRow) -eq 'codexbar-cli' -and
        (Test-UsageProbeEligible -Provider $barRow))

    # ---- binary resolution, still without ever launching one ----
    $savedPath = $env:PATH
    $savedLocalAppData = $env:LOCALAPPDATA
    try {
        $env:PATH = $tmp
        $env:LOCALAPPDATA = $tmp
        Check 'B22 no probe_command, nothing on PATH, nothing installed -> no binary' (
            $null -eq (Resolve-CodexBarBinaryPath))
        Check 'B22 an unresolvable binary returns null without throwing' (
            $null -eq (Invoke-CodexBarUsageTransport -ProbeProvider 'provider-a' -TimeoutSeconds 5))
    } finally {
        $env:PATH = $savedPath
        $env:LOCALAPPDATA = $savedLocalAppData
    }
    $missingBinary = Join-Path $tmp 'no-such-probe-binary.exe'
    Check 'B23 an explicit probe_command that does not exist returns null without throwing' (
        ($missingBinary -eq (Resolve-CodexBarBinaryPath -ProbeCommand $missingBinary)) -and
        ($null -eq (Invoke-CodexBarUsageTransport -ProbeProvider 'provider-a' -TimeoutSeconds 5 -ProbeCommand $missingBinary)))

    # ---- end to end through the generic probe entry ----
    $e2eState = @{ calls = 0 }
    $e2eRunner = New-CodexBarFakeRunner -Stdout $scopedJson -State $e2eState
    $e2eTransport = {
        param($clientVersion, $timeoutSeconds, $providerRow)
        # Proves the provider ROW reaches the transport: the account queried comes
        # from usage_policy.probe_provider, never from a guess.
        Invoke-CodexBarUsageTransport -TimeoutSeconds $timeoutSeconds -Runner $e2eRunner `
            -ProbeProvider ([string](Get-UsagePolicyField -Policy $providerRow.usage_policy -Field 'probe_provider'))
    }.GetNewClosure()
    $e2eCache = Join-Path $tmp 'codexbar-e2e.jsonl'
    $e2eSnapshot = Get-ProviderUsageProbe -Worker 'worker-bar' -Provider $barRow -Transport $e2eTransport `
        -CachePath $e2eCache -Now $T0 -TimeoutSeconds 20 -TtlSeconds 600
    Check 'B24 generic probe entry returns the standard snapshot shape for codexbar' (
        $null -ne $e2eSnapshot -and @($e2eSnapshot.observations).Count -eq 3 -and
        $e2eSnapshot.cached -eq $false -and [int]$e2eSnapshot.ttl -eq 600 -and
        $e2eState.calls -eq 1 -and (Test-Path -LiteralPath $e2eCache))
    $e2eCached = Get-FreshUsageProbeCache -Worker 'worker-bar' -CachePath $e2eCache -Now $T0.AddMinutes(5)
    Check 'B25 codexbar observations survive the JSON cache round-trip with scope_id intact' (
        $null -ne $e2eCached -and
        (@($e2eCached.observations | Where-Object { [string]$_.scope_id -eq 'scope-window-a' }).Count -eq 1))

    # =======================================================================
    # SCOPE BINDING — the plan-dependent-window contract
    # =======================================================================
    $unboundRow = @{
        name = 'worker-unbound'; kind = 'cli'; platform = 'platform-b'
        usage_policy = @{ probe = $true; probe_transport = 'codexbar-cli'; probe_provider = 'provider-a'
                          soft_cap_5h = [double]75; soft_cap_weekly = [double]85 }
    }
    $boundRow = @{
        name = 'worker-bound'; kind = 'cli'; platform = 'platform-b'
        usage_policy = @{ probe = $true; probe_transport = 'codexbar-cli'; probe_provider = 'provider-a'
                          scope_id = 'scope-window-a'
                          soft_cap_5h = [double]75; soft_cap_weekly = [double]85 }
    }
    # Plan-wide weekly comfortably UNDER cap; the scoped sub-quota fully exhausted.
    $roomyPlanScopedFullObs = Get-CodexBarFakeObservation -Json (
        New-SyntheticCodexBarJson -WeeklyUsed '42' `
            -ExtraWindowsJson (New-SyntheticScopedWindowJson -Id 'scope-window-a' -Used '100'))
    $boundDecision = Get-UsageProbeCapDecision -Provider $boundRow -Observations @($roomyPlanScopedFullObs)
    Check 'SB1 a BOUND row is over cap on its exhausted sub-quota while plan-wide has room' (
        $boundDecision.over_cap -and @($boundDecision.windows).Count -eq 1 -and
        [string]$boundDecision.windows[0].scope_id -eq 'scope-window-a' -and
        [double]$boundDecision.windows[0].used_pct -eq 100 -and
        [string]$boundDecision.windows[0].policy_knob -eq 'soft_cap_weekly')
    $unboundDecision = Get-UsageProbeCapDecision -Provider $unboundRow -Observations @($roomyPlanScopedFullObs)
    Check 'SB2 an UNBOUND row ignores another scope sub-quota and stays under cap' (
        (-not $unboundDecision.over_cap) -and
        (@($unboundDecision.checked | Where-Object { $null -ne $_.scope_id }).Count -eq 0) -and
        @($unboundDecision.checked).Count -eq 2)

    # -----------------------------------------------------------------------
    # SB3/SB4 — THE FALLBACK CHECK.
    # The set of windows is plan-dependent: a tier change REMOVES a scoped window
    # from the response entirely. A row still bound to that now-missing scope_id
    # must fall back to the PLAN-WIDE weekly window — never to "unlimited".
    # Inverting this would silently uncap the row at the exact moment the plan
    # was downgraded, which is the failure this pair of checks exists to prevent.
    # -----------------------------------------------------------------------
    $planOnlyOverObs = Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson -WeeklyUsed '91.5')
    Check 'SB3 FALLBACK: bound row, scope_id ABSENT from the response, plan-wide over cap -> HELD (not uncapped)' (
        (@($planOnlyOverObs | Where-Object { $null -ne $_.scope_id }).Count -eq 0) -and
        (($boundDecision = Get-UsageProbeCapDecision -Provider $boundRow -Observations @($planOnlyOverObs)).over_cap) -and
        (@($boundDecision.windows | Where-Object { [string]$_.window -eq 'weekly' }).Count -eq 1) -and
        ([double]@($boundDecision.windows | Where-Object { [string]$_.window -eq 'weekly' })[0].used_pct -eq 91.5) -and
        ($null -eq @($boundDecision.windows | Where-Object { [string]$_.window -eq 'weekly' })[0].scope_id))
    $planOnlyUnderObs = Get-CodexBarFakeObservation -Json (New-SyntheticCodexBarJson -WeeklyUsed '42')
    $missingScopeUnder = Get-UsageProbeCapDecision -Provider $boundRow -Observations @($planOnlyUnderObs)
    Check 'SB4 FALLBACK: a missing scope_id still EVALUATES both plan-wide windows (loses info, not caps)' (
        (-not $missingScopeUnder.over_cap) -and @($missingScopeUnder.checked).Count -eq 2 -and
        ((@($missingScopeUnder.checked | ForEach-Object { [string]$_.window } | Sort-Object) -join ',') -eq 'five_hour,weekly'))
    # And the same row bound to an id nothing will ever emit behaves identically —
    # nothing keys off a known window id.
    $strangerRow = @{
        name = 'worker-stranger'; kind = 'cli'; platform = 'platform-b'
        usage_policy = @{ probe = $true; probe_transport = 'codexbar-cli'; probe_provider = 'provider-a'
                          scope_id = 'scope-window-never-emitted'
                          soft_cap_5h = [double]75; soft_cap_weekly = [double]85 }
    }
    $strangerDecision = Get-UsageProbeCapDecision -Provider $strangerRow -Observations @($roomyPlanScopedFullObs)
    Check 'SB5 a row bound to an unknown scope id is judged plan-wide, and ignores foreign sub-quotas' (
        (-not $strangerDecision.over_cap) -and @($strangerDecision.checked).Count -eq 2)

    # Plan-wide over cap AND the bound sub-quota exhausted: both crossings survive.
    $bothOverObs = Get-CodexBarFakeObservation -Json (
        New-SyntheticCodexBarJson -WeeklyUsed '91.5' `
            -ExtraWindowsJson (New-SyntheticScopedWindowJson -Id 'scope-window-a' -Used '100'))
    $bothOverDecision = Get-UsageProbeCapDecision -Provider $boundRow -Observations @($bothOverObs)
    Check 'SB6 plan-wide and bound-scope crossings are both reported' (
        $bothOverDecision.over_cap -and @($bothOverDecision.windows).Count -eq 2)
    $scopedHoldLine = Format-UsagePreflightLine -Worker 'worker-bound' -WindowDecision $bothOverDecision.windows -Outcome held
    Check 'SB7 the hold line names the crossed sub-quota so it reads as scoped, not plan-wide' (
        $scopedHoldLine -match 'scope scope-window-a' -and $scopedHoldLine -match 'soft_cap_weekly')
    $scopedJournal = Join-Path $tmp 'codexbar-limited.jsonl'
    Add-UsageProbeLimitedRows -Worker 'worker-bound' -Decision $bothOverDecision -UsagePath $scopedJournal
    $scopedLimitedRows = @(Get-Content -LiteralPath $scopedJournal | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'SB8 limited rows keep codexbar provenance and the scope id' (
        $scopedLimitedRows.Count -eq 2 -and
        (@($scopedLimitedRows | Where-Object { [string]$_.source -eq 'codexbar:source-a' }).Count -eq 2) -and
        (@($scopedLimitedRows | Where-Object { [string]$_.scope_id -eq 'scope-window-a' }).Count -eq 1))

    # Unchanged contract: codexbar observations feed the existing cap decision.
    $overCapRow = @{
        name = 'worker-bar'; kind = 'cli'; platform = 'platform-b'
        usage_policy = @{ probe = $true; probe_transport = 'codexbar-cli'; probe_provider = 'provider-a'
                          soft_cap_5h = [double]75; soft_cap_weekly = [double]85 }
    }
    $overCapDecision = Get-UsageProbeCapDecision -Provider $overCapRow -Observations @($planOnlyOverObs)
    Check 'SB9 a weekly figure past soft_cap_weekly is over cap through the unchanged decision path' (
        $overCapDecision.over_cap -and [string]$overCapDecision.windows[0].window -eq 'weekly' -and
        [string]$overCapDecision.windows[0].policy_knob -eq 'soft_cap_weekly')

    # ── OpenRouter credit probe (prepaid balance, scope paid_credit) ──────────
    $orNow = [datetimeoffset]::Parse('2026-08-13T18:00:00Z')
    $orRow = @{
        name = 'openrouter'; kind = 'http'; platform = 'openrouter'
        base_url = 'https://openrouter.test/api'; api_key_env = 'BATON_TEST_OR_KEY'
        usage_policy = @{ probe = $true; probe_transport = 'openrouter-key'; soft_cap_credit = [double]85 }
    }
    function New-OrKeyResponse($Limit, $Usage, $Reset) {
        $data = [ordered]@{ label = 'sk-or-v1-abc...xyz'; limit = $Limit; usage = $Usage }
        if ($null -ne $Reset) { $data.limit_reset = $Reset }
        return ([pscustomobject]@{ data = [pscustomobject]$data })
    }

    $orObs = ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' `
        -Response (New-OrKeyResponse 20 5 $null) -ObservedAt $orNow -TtlSeconds 600
    Check 'OR1 usage over limit becomes a paid_credit observation with the right percent' (
        @($orObs).Count -eq 1 -and [string]$orObs[0].scope -eq 'paid_credit' -and
        [double]$orObs[0].used_pct -eq 25 -and [double]$orObs[0].consumed -eq 5 -and
        [double]$orObs[0].allowance -eq 20 -and
        [string]$orObs[0].source -eq 'openrouter_key_probe')
    Check 'OR2 a prepaid balance invents no reset_at' (
        -not $orObs[0].Contains('reset_at') -and -not $orObs[0].Contains('limit_reset'))

    $orCycle = ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' `
        -Response (New-OrKeyResponse 20 5 'monthly') -ObservedAt $orNow -TtlSeconds 600
    Check 'OR3 a vendor-declared cycle is carried through' ([string]$orCycle[0].limit_reset -eq 'monthly')

    Check 'OR4 an uncapped key yields NO observation rather than 0 percent' (
        $null -eq (ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' `
            -Response (New-OrKeyResponse $null 5 $null) -ObservedAt $orNow -TtlSeconds 600))
    Check 'OR5 malformed and missing figures yield null' (
        ($null -eq (ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' `
            -Response (New-OrKeyResponse 'lots' 5 $null) -ObservedAt $orNow -TtlSeconds 600)) -and
        ($null -eq (ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' `
            -Response ([pscustomobject]@{ data = [pscustomobject]@{ label = 'x' } }) -ObservedAt $orNow -TtlSeconds 600)) -and
        ($null -eq (ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' `
            -Response ([pscustomobject]@{ nothing = $true }) -ObservedAt $orNow -TtlSeconds 600)))
    Check 'OR6 overspend clamps to 100 rather than exceeding the percentage scale' (
        [double](ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' `
            -Response (New-OrKeyResponse 20 25 $null) -ObservedAt $orNow -TtlSeconds 600)[0].used_pct -eq 100)

    # Identity fails closed: no key, no probe, and provably no network call.
    $savedOrKey = $env:BATON_TEST_OR_KEY
    try {
        $env:BATON_TEST_OR_KEY = $null
        $script:orCalled = $false
        $noKeyResult = Invoke-OpenRouterKeyTransport -Provider $orRow -TimeoutSeconds 5 `
            -Invoker { param($uri, $headers, $timeout) $script:orCalled = $true; return 'should-not-happen' }
        Check 'OR7 an unset api_key_env probes nothing and calls nothing' (
            $null -eq $noKeyResult -and -not $script:orCalled)

        $anonRow = @{ name = 'anon'; kind = 'http'; platform = 'openrouter'; base_url = 'https://openrouter.test/api' }
        $script:orCalled = $false
        $noDeclResult = Invoke-OpenRouterKeyTransport -Provider $anonRow -TimeoutSeconds 5 `
            -Invoker { param($uri, $headers, $timeout) $script:orCalled = $true; return 'should-not-happen' }
        Check 'OR8 a row with no api_key_env never probes anonymously' (
            $null -eq $noDeclResult -and -not $script:orCalled)

        $env:BATON_TEST_OR_KEY = 'sk-or-test-secret'
        $script:orUri = ''
        $script:orAuth = ''
        $liveResult = Invoke-OpenRouterKeyTransport -Provider $orRow -TimeoutSeconds 5 -Invoker {
            param($uri, $headers, $timeout)
            $script:orUri = [string]$uri
            $script:orAuth = [string]$headers.Authorization
            return (New-OrKeyResponse 20 5 $null)
        }
        Check 'OR9 the probe hits /v1/key with the row credential' (
            $script:orUri -eq 'https://openrouter.test/api/v1/key' -and
            $script:orAuth -eq 'Bearer sk-or-test-secret' -and
            [double]$liveResult.data.limit -eq 20)

        # The credential must not survive into the cache file.
        $orCachePath = Join-Path $tmp 'openrouter-cache.jsonl'
        $orSnapshot = Get-ProviderUsageProbe -Worker 'openrouter' -TransportName 'openrouter-key' `
            -Provider $orRow -CachePath $orCachePath -Now $orNow -TimeoutSeconds 5 -TtlSeconds 600 `
            -Transport { param($clientVersion, $timeoutSeconds, $providerRow) New-OrKeyResponse 20 18 $null }
        Check 'OR10 the registry drives the probe end to end' (
            $null -ne $orSnapshot -and @($orSnapshot.observations).Count -eq 1 -and
            [double]$orSnapshot.observations[0].used_pct -eq 90)
        Check 'OR11 the credential never lands in the probe cache' (
            (Get-Content -LiteralPath $orCachePath -Raw) -notmatch 'sk-or-test-secret')

        # The whole point: a credit crossing must gate dispatch like any window.
        $orOverDecision = Get-UsageProbeCapDecision -Provider $orRow -Observations @($orSnapshot.observations)
        Check 'OR12 spending past soft_cap_credit is over cap' (
            $orOverDecision.over_cap -and
            [string]$orOverDecision.windows[0].window -eq 'paid_credit' -and
            [string]$orOverDecision.windows[0].policy_knob -eq 'soft_cap_credit')

        $orUnderDecision = Get-UsageProbeCapDecision -Provider $orRow -Observations @($orObs)
        Check 'OR13 spending under soft_cap_credit is not over cap' (
            -not $orUnderDecision.over_cap -and @($orUnderDecision.checked).Count -eq 1)

        # Preflight provenance must follow the transport that observed it.
        $orEventPath = Join-Path $tmp 'openrouter-preflight.jsonl'
        Add-UsagePreflightEvent -Worker 'openrouter' -Outcome 'held' `
            -WindowDecision $orOverDecision.windows -UsagePath $orEventPath -Timestamp $orNow.ToString('o')
        $orEvent = @(Get-Content -LiteralPath $orEventPath | ForEach-Object { $_ | ConvertFrom-Json })[0]
        Check 'OR14 preflight events are attributed to the observing transport' (
            [string]$orEvent.source -eq 'openrouter_key_probe')
    } finally {
        $env:BATON_TEST_OR_KEY = $savedOrKey
    }

    # ── Fixes from the adversarial review (grok, 2026-08-13) ─────────────────
    # R1: JSON money fields arrive as [double]; stringifying them under a
    # comma-decimal culture used to produce "25,5", which the invariant parse
    # rejected -> no observation -> read as headroom.
    $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
        $cultureObs = ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' `
            -Response (New-OrKeyResponse ([double]20.0) ([double]5.5) $null) -ObservedAt $orNow -TtlSeconds 600
        # Rounded compare: (5.5/20)*100 is 27.500000000000004 in binary floating
        # point. The contract is the percentage, not the last ulp.
        Check 'R1 fractional dollars survive a comma-decimal culture' (
            @($cultureObs).Count -eq 1 -and
            [math]::Round([double]$cultureObs[0].used_pct, 6) -eq 27.5)
    } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
    }
    Check 'R1b non-numeric and boolean money fields are still rejected' (
        ($null -eq (ConvertTo-ProbeDouble 'lots')) -and ($null -eq (ConvertTo-ProbeDouble $true)) -and
        ($null -eq (ConvertTo-ProbeDouble $null)) -and ([double](ConvertTo-ProbeDouble '25.5') -eq 25.5))

    # R2: limit_remaining wins over all-time usage, so a resetting key is not
    # pinned at 100% forever once cumulative usage passes one cycle's limit.
    $cycleData = [pscustomobject]@{ data = [pscustomobject]@{
        label = 'sk-or-v1-abc...xyz'; limit = 20; limit_remaining = 18; usage = 95; limit_reset = 'monthly' } }
    $cycleObs = ConvertFrom-OpenRouterKeyResponse -Worker 'openrouter' -Response $cycleData `
        -ObservedAt $orNow -TtlSeconds 600
    Check 'R2 limit_remaining beats all-time usage on a resetting key' (
        [double]$cycleObs[0].used_pct -eq 10 -and [double]$cycleObs[0].consumed -eq 2)

    # R3: the truncated key label must not reach the cache.
    $savedOrKey2 = $env:BATON_TEST_OR_KEY
    try {
        $env:BATON_TEST_OR_KEY = 'sk-or-test-secret'
        $labelled = Invoke-OpenRouterKeyTransport -Provider $orRow -TimeoutSeconds 5 -Invoker {
            param($uri, $headers, $timeout)
            [pscustomobject]@{ data = [pscustomobject]@{ label = 'sk-or-v1-au7...890'; limit = 20; usage = 5 } }
        }
        Check 'R3 the key label is redacted before the body is ever cached' (
            [string]$labelled.data.label -eq '<redacted>')

        # R4: a cached row is bound to the credential that produced it.
        $rotPath = Join-Path $tmp 'openrouter-rotate.jsonl'
        $script:rotCalls = 0
        $rotProbe = { param($clientVersion, $timeoutSeconds, $providerRow)
                      $script:rotCalls++; New-OrKeyResponse 20 5 $null }
        [void](Get-ProviderUsageProbe -Worker 'openrouter' -TransportName 'openrouter-key' -Provider $orRow `
            -CachePath $rotPath -Now $orNow -TimeoutSeconds 5 -TtlSeconds 600 -Transport $rotProbe)
        [void](Get-ProviderUsageProbe -Worker 'openrouter' -TransportName 'openrouter-key' -Provider $orRow `
            -CachePath $rotPath -Now $orNow -TimeoutSeconds 5 -TtlSeconds 600 -Transport $rotProbe)
        Check 'R4 the same key reuses the cached row' ($script:rotCalls -eq 1)

        $env:BATON_TEST_OR_KEY = 'sk-or-DIFFERENT-account'
        [void](Get-ProviderUsageProbe -Worker 'openrouter' -TransportName 'openrouter-key' -Provider $orRow `
            -CachePath $rotPath -Now $orNow -TimeoutSeconds 5 -TtlSeconds 600 -Transport $rotProbe)
        Check 'R4b a rotated key refuses the previous account cached row' ($script:rotCalls -eq 2)

        $env:BATON_TEST_OR_KEY = $null
        $unsetSnapshot = Get-ProviderUsageProbe -Worker 'openrouter' -TransportName 'openrouter-key' -Provider $orRow `
            -CachePath $rotPath -Now $orNow -TimeoutSeconds 5 -TtlSeconds 600 -Transport $rotProbe
        Check 'R4c an unset key serves no cached row at all' (
            $null -eq $unsetSnapshot -and $script:rotCalls -eq 2)
    } finally {
        $env:BATON_TEST_OR_KEY = $savedOrKey2
    }

    # ── E: the cap must actually gate Invoke-Fleet, not just produce a verdict ──
    $savedOrKey3 = $env:BATON_TEST_OR_KEY
    try {
        $env:BATON_TEST_OR_KEY = 'sk-or-enforce-secret'
        $capFleet = Join-Path $tmp 'enforce-fleet.yaml'
        Set-Content -LiteralPath $capFleet -Encoding utf8NoBOM -Value @"
providers:
  - name: openrouter
    kind: http
    enabled: true
    cost_tier: paid
    platform: openrouter
    base_url: 'https://openrouter.test/api'
    model_default: 'vendor/model'
    api_key_env: BATON_TEST_OR_KEY
    usage_policy:
      probe: true
      probe_transport: openrouter-key
      soft_cap_credit: 85
"@
        $capRow = Get-FleetProvider -Name 'openrouter' -Path $capFleet
        $capUsage = Join-Path $tmp 'enforce-usage.jsonl'
        $capCache = Join-Path $tmp 'enforce-cache.jsonl'

        # Over cap (90% of 20 USD) -> blocked, journalled, no dispatch.
        Add-UsageProbeCacheRow -Worker 'openrouter' -Raw ([pscustomobject]@{ data = 'x' }) `
            -CachePath $capCache -ObservedAt $orNow -TtlSeconds 600 `
            -Identity (Get-ProbeIdentityFingerprint -Secret 'sk-or-enforce-secret') `
            -Observations @([ordered]@{
                worker = 'openrouter'; scope = 'paid_credit'; used_pct = [double]90
                consumed = [double]18; allowance = [double]20; source = 'openrouter_key_probe'
                observed_at = $orNow.ToString('o'); ttl = 600; confidence = [double]0.95 })
        $overSnapshot = Get-ProviderUsageProbe -Worker 'openrouter' -Provider $capRow `
            -CachePath $capCache -Now $orNow
        $overDecision = Get-UsageProbeCapDecision -Provider $capRow -Observations @($overSnapshot.observations)
        Check 'E1 a cached prepaid crossing is detected through the generic entry' (
            $overDecision.over_cap -and [string]$overDecision.windows[0].window -eq 'paid_credit')

        Add-UsageProbeLimitedRows -Worker 'openrouter' -Decision $overDecision -UsagePath $capUsage
        $limitedRow = @(Get-Content -LiteralPath $capUsage | ForEach-Object { $_ | ConvertFrom-Json })[0]
        Check 'E2 the crossing journals under the openrouter transport, not codex' (
            [string]$limitedRow.source -eq 'openrouter_key_probe' -and
            [string]$limitedRow.scope -eq 'paid_credit')

        # Under cap -> no crossing, dispatch proceeds.
        $underDecision = Get-UsageProbeCapDecision -Provider $capRow -Observations @([ordered]@{
            worker = 'openrouter'; scope = 'paid_credit'; used_pct = [double]10
            source = 'openrouter_key_probe'; observed_at = $orNow.ToString('o')
            ttl = 600; confidence = [double]0.95 })
        Check 'E3 under the cap there is no crossing to act on' (-not $underDecision.over_cap)

        # A subscription window must NOT be caught by the prepaid-only guard.
        $subOnly = Get-UsageProbeCapDecision -Provider @{
            name = 'codexish'; usage_policy = @{ soft_cap_weekly = [double]85; soft_cap_credit = [double]85 } } `
            -Observations @([ordered]@{
                worker = 'codexish'; scope = 'weekly'; used_pct = [double]99
                source = 'app_server_probe'; observed_at = $orNow.ToString('o')
                ttl = 600; confidence = [double]0.95 })
        # E5-E7 are the checks that OR12 was missing: they drive the REAL entry
        # point, so they fail if the guard is not wired into dispatch at all.
        # base_url is unroutable, so a dispatch that slips past the cap fails with
        # a transport error -- never mistakable for a cap refusal.
        #
        # Invoke-Fleet resolves the probe cache from BATON_HOME, so the crossing
        # has to be seeded THERE; pointing it at a fixture path would test a cache
        # the production path never reads.
        Add-UsageProbeCacheRow -Worker 'openrouter' -Raw ([pscustomobject]@{ data = 'x' }) `
            -ObservedAt ([datetimeoffset]::UtcNow) -TtlSeconds 600 `
            -Identity (Get-ProbeIdentityFingerprint -Secret 'sk-or-enforce-secret') `
            -Observations @([ordered]@{
                worker = 'openrouter'; scope = 'paid_credit'; used_pct = [double]90
                consumed = [double]18; allowance = [double]20; source = 'openrouter_key_probe'
                observed_at = ([datetimeoffset]::UtcNow).ToString('o'); ttl = 600; confidence = [double]0.95 })
        $blockedCall = Invoke-Fleet -Name 'openrouter' -Prompt 'should not be sent' -Path $capFleet `
            -UsagePath (Join-Path $tmp 'e5-usage.jsonl') -NoJournal
        Check 'E5 Invoke-Fleet REFUSES to dispatch past the prepaid cap' (
            [string]$blockedCall.skipped -eq 'prepaid_cap_reached' -and
            [int]$blockedCall.exit_code -ne 0 -and
            [string]$blockedCall.stderr -match 'prepaid credit' -and
            [string]$blockedCall.stdout -eq '')

        $e5Usage = @(Get-Content -LiteralPath (Join-Path $tmp 'e5-usage.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        Check 'E5b the refusal is journalled as limited + held preflight' (
            @($e5Usage | Where-Object { [string]$_.event -eq 'limited' }).Count -ge 1 -and
            @($e5Usage | Where-Object { [string]$_.event -eq 'preflight' -and [string]$_.outcome -eq 'held' }).Count -ge 1)
        # Baton's own refusal must not be re-read as a PROVIDER quota failure --
        # that would lock out a provider that is working fine and never saw the
        # request. The guard's wording sits one comma from the quota pattern.
        Check 'E5c a cap refusal is never classified as a provider failure' (
            [string]$blockedCall.usage_observation.classification -eq 'none' -and
            $null -eq $blockedCall.usage_observation.event -and
            @($e5Usage | Where-Object {
                [string]$_.classification -eq 'quota_exhausted' -or
                [string]$_.classification -eq 'rate_limit_burst' -or
                [string]$_.classification -eq 'context_overflow' }).Count -eq 0)

        # Fail open: an unknown balance dispatches rather than wedging the fleet.
        # Rotating the key invalidates the seeded row by identity, so there is no
        # usable observation; the unroutable host then produces a transport
        # failure -- which is proof we got PAST the guard rather than blocked by it.
        $env:BATON_TEST_OR_KEY = 'sk-or-rotated-no-cache'
        $openCall = Invoke-Fleet -Name 'openrouter' -Prompt 'hello' -Path $capFleet `
            -UsagePath (Join-Path $tmp 'e6-usage.jsonl') -NoJournal
        Check 'E6 an unknown balance fails OPEN and still attempts dispatch' (
            [string]$openCall.skipped -ne 'prepaid_cap_reached' -and
            [int]$openCall.exit_code -ne 0)

        # And the escape hatch stays honest.
        $bypassCall = Invoke-Fleet -Name 'openrouter' -Prompt 'hello' -Path $capFleet `
            -UsagePath (Join-Path $tmp 'e7-usage.jsonl') -NoJournal -NoPrepaidCap
        Check 'E7 -NoPrepaidCap bypasses the guard' (
            [string]$bypassCall.skipped -ne 'prepaid_cap_reached')

        Check 'E4 a weekly crossing yields no paid_credit window for the prepaid guard' (
            $subOnly.over_cap -and
            @($subOnly.windows | Where-Object { [string]$_.window -eq 'paid_credit' }).Count -eq 0)
    } finally {
        $env:BATON_TEST_OR_KEY = $savedOrKey3
    }

    Check 'OR15 openrouter-key is a registered transport' (
        (Get-UsageProbeTransportName) -contains 'openrouter-key')
    Check 'OR16 an http openrouter row infers the transport without declaring it' (
        (Resolve-UsageProbeTransportName -Provider @{
            kind = 'http'; platform = 'openrouter'; usage_policy = @{ probe = $true } }) -eq 'openrouter-key')
    Check 'OR17 eligibility holds for the inferred row' (
        Test-UsageProbeEligible -Provider @{
            kind = 'http'; platform = 'openrouter'; usage_policy = @{ probe = $true } })
} finally {
    $env:BATON_HOME = $savedBatonHome
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED"; exit 1 }
Write-Host "`nALL PASS"; exit 0
