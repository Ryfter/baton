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
    'Add-UsageProbeCacheRow',
    'Get-FreshUsageProbeCache',
    'Get-CodexUsageProbe',
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
} finally {
    $env:BATON_HOME = $savedBatonHome
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED"; exit 1 }
Write-Host "`nALL PASS"; exit 0
