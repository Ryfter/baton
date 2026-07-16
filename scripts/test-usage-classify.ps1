#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$script:failureCount = 0
function Check($Name, $Condition) {
    if ($Condition) { Write-Host "PASS: $Name" }
    else { Write-Host "FAIL: $Name"; $script:failureCount++ }
}
function As-IsoString($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    return [string]$Value
}

$libPath = Join-Path $PSScriptRoot 'usage-classify-lib.ps1'
if (-not (Test-Path -LiteralPath $libPath)) {
    Write-Host 'FAIL: usage-classify-lib.ps1 exists'
    exit 1
}
. $libPath

$now = [datetime]::SpecifyKind([datetime]'2098-12-31T23:00:00', [DateTimeKind]::Utc)

$cases = @(
    @{
        name = 'Codex quota exhausted'
        exit_code = 1
        stdout = ''
        stderr = "You've hit your usage limit. Try again at 2099-01-01T00:00:00Z."
        classification = 'quota_exhausted'
        event_kind = 'lockout'
        hard = $true
        scope = 'subscription'
        reset_at = '2099-01-01T00:00:00.0000000Z'
    },
    @{
        name = 'Claude weekly limit'
        exit_code = 1
        stdout = 'You have hit your weekly limit. Resets at 2099-01-02T00:00:00Z.'
        stderr = ''
        classification = 'quota_exhausted'
        event_kind = 'lockout'
        hard = $true
        scope = 'weekly'
        reset_at = '2099-01-02T00:00:00.0000000Z'
    },
    @{
        name = 'Claude short limit phrase'
        exit_code = 1
        stdout = ''
        stderr = "You've hit your limit. Resets at 2099-01-03T00:00:00Z."
        classification = 'quota_exhausted'
        event_kind = 'lockout'
        hard = $true
        scope = 'subscription'
        reset_at = '2099-01-03T00:00:00.0000000Z'
    },
    @{
        name = 'Grok subscription limit'
        exit_code = 1
        stdout = ''
        stderr = 'Usage limit reached for this subscription. Resets in 2h.'
        classification = 'quota_exhausted'
        event_kind = 'lockout'
        hard = $true
        scope = 'subscription'
        reset_at = '2099-01-01T01:00:00.0000000Z'
    },
    @{
        name = 'generic 429 burst'
        exit_code = 1
        stdout = ''
        stderr = "HTTP 429 Too Many Requests`nRetry-After: 120"
        classification = 'rate_limit_burst'
        event_kind = 'cooldown'
        hard = $true
        scope = 'api_rate'
        reset_at = '2098-12-31T23:02:00.0000000Z'
    },
    @{
        name = '429 HTTP-date reset'
        exit_code = 1
        stdout = ''
        stderr = "HTTP 429 Too Many Requests`nRetry-After: Thu, 01 Jan 2099 00:05:00 GMT"
        classification = 'rate_limit_burst'
        event_kind = 'cooldown'
        hard = $true
        scope = 'api_rate'
        reset_at = '2099-01-01T00:05:00.0000000Z'
    },
    @{
        name = 'Codex clock reset'
        exit_code = 1
        stdout = ''
        stderr = "You've hit your usage limit. Try again at 01:30 UTC."
        classification = 'quota_exhausted'
        event_kind = 'lockout'
        hard = $true
        scope = 'subscription'
        reset_at = '2099-01-01T01:30:00.0000000Z'
    },
    @{
        name = 'server overload'
        exit_code = 1
        stdout = ''
        stderr = 'HTTP 529 overloaded_error: server is overloaded'
        classification = 'server_overload'
        event_kind = 'cooldown'
        hard = $false
        scope = 'api_rate'
        reset_at = '2098-12-31T23:15:00.0000000Z'
    },
    @{
        name = 'auth config'
        exit_code = 1
        stdout = ''
        stderr = 'HTTP 401 invalid API key; authentication required'
        classification = 'auth_config'
        event_kind = $null
        hard = $false
        scope = 'subscription'
        reset_at = $null
    },
    @{
        name = 'ambiguous failure'
        exit_code = 1
        stdout = ''
        stderr = 'remote command ended unexpectedly'
        classification = 'ambiguous'
        event_kind = 'cooldown'
        hard = $false
        scope = 'api_rate'
        reset_at = '2098-12-31T23:05:00.0000000Z'
    },
    @{
        name = 'auth+quota co-occurrence'
        exit_code = 1
        stdout = ''
        stderr = 'HTTP 401 unauthorized: invalid API key; usage limit exceeded'
        classification = 'auth_config'
        event_kind = $null
        hard = $false
        scope = 'subscription'
        reset_at = $null
    },
    @{
        name = 'hit your limit of N retries'
        exit_code = 1
        stdout = ''
        stderr = 'hit your limit of 3 retries'
        classification = 'ambiguous'
        event_kind = 'cooldown'
        hard = $false
        scope = 'api_rate'
        reset_at = '2098-12-31T23:05:00.0000000Z'
    },
    @{
        name = 'bare retry after fixing tests'
        exit_code = 1
        stdout = ''
        stderr = 'retry after fixing tests'
        classification = 'ambiguous'
        event_kind = 'cooldown'
        hard = $false
        scope = 'api_rate'
        reset_at = '2098-12-31T23:05:00.0000000Z'
    },
    @{
        name = 'Youve hit your rate limit'
        exit_code = 1
        stdout = ''
        stderr = "You've hit your rate limit"
        classification = 'rate_limit_burst'
        event_kind = 'cooldown'
        hard = $true
        scope = 'api_rate'
        reset_at = '2098-12-31T23:15:00.0000000Z'
    },
    @{
        name = 'Claude rate_limit_error'
        exit_code = 1
        stdout = ''
        stderr = 'Error: rate_limit_error (request id: abc)'
        classification = 'rate_limit_burst'
        event_kind = 'cooldown'
        hard = $true
        scope = 'api_rate'
        reset_at = '2098-12-31T23:15:00.0000000Z'
    },
    @{
        name = 'quota with no reset uses bounded TTL'
        exit_code = 1
        stdout = ''
        stderr = 'quota exhausted'
        classification = 'quota_exhausted'
        event_kind = 'lockout'
        hard = $true
        scope = 'subscription'
        reset_at = '2099-01-01T05:00:00.0000000Z'  # now + 6h
        ttl = 21600
    },
    @{
        name = 'model quota no reset uses 1h TTL'
        exit_code = 1
        stdout = ''
        stderr = 'You hit your model limit for opus'
        classification = 'quota_exhausted'
        event_kind = 'lockout'
        hard = $true
        scope = 'model'
        reset_at = '2099-01-01T00:00:00.0000000Z'  # now + 1h
        ttl = 3600
    }
)

foreach ($case in $cases) {
    $observation = Get-UsageFailureObservation -ExitCode $case.exit_code -Stdout $case.stdout -Stderr $case.stderr -Now $now
    Check "$($case.name): classification" ($observation.classification -eq $case.classification)
    Check "$($case.name): event" ($observation.event -eq $case.event_kind)
    Check "$($case.name): hard failover" ($observation.hard_failover -eq $case.hard)
    Check "$($case.name): scope" ($observation.scope -eq $case.scope)
    Check "$($case.name): reset" ($observation.reset_at -eq $case.reset_at)
    Check "$($case.name): normalized source" ($observation.source -eq 'error_classify')
    Check "$($case.name): observed_at" ($observation.observed_at -eq '2098-12-31T23:00:00.0000000Z')
    Check "$($case.name): ttl positive" ([int]$observation.ttl -gt 0)
    if ($case.ContainsKey('ttl')) {
        Check "$($case.name): ttl exact" ([int]$observation.ttl -eq [int]$case.ttl)
    }
    Check "$($case.name): confidence bounded" ([double]$observation.confidence -gt 0 -and [double]$observation.confidence -le 1)
}

$success = Get-UsageFailureObservation -ExitCode 0 -Stdout 'normal response' -Stderr '' -Now $now
Check 'successful dispatch has no journal event' ($null -eq $success.event)
Check 'successful dispatch does not fail over' (-not $success.hard_failover)

# Zone-less clock: LOCAL time emitted as ISO-8601 WITH offset (machine-independent via fixed -Now).
$zoneLessText = "You've hit your usage limit. Try again at 01:30."
$zoneLessObs = Get-UsageFailureObservation -ExitCode 1 -Stdout '' -Stderr $zoneLessText -Now $now
$nowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc($now, [System.TimeZoneInfo]::Local)
$dayBase = $nowLocal.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
$expectedClock = [datetimeoffset]::MinValue
$parsedOk = [datetimeoffset]::TryParse(
    ($dayBase + ' 01:30'),
    [System.Globalization.CultureInfo]::InvariantCulture,
    ([System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [System.Globalization.DateTimeStyles]::AssumeLocal),
    [ref]$expectedClock)
if ($parsedOk -and $expectedClock.UtcDateTime -le $now) { $expectedClock = $expectedClock.AddDays(1) }
Check 'zone-less clock parses under fixed Now' $parsedOk
Check 'zone-less clock emits offset form' ($zoneLessObs.reset_at -match '[+-]\d{2}:\d{2}$')
Check 'zone-less clock matches AssumeLocal instant' ($zoneLessObs.reset_at -eq $expectedClock.ToString('o'))
Check 'zone-less clock is not silent-Z UTC relabel' ($zoneLessObs.reset_at -notmatch 'Z$')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("usage-classify-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $usagePath = Join-Path $tempRoot 'usage-journal.jsonl'
    $quotaObservation = Register-UsageFailure -Worker 'worker-quota' -ExitCode 1 -Stdout '' `
        -Stderr "You've hit your usage limit. Try again at 2099-01-01T00:00:00Z." `
        -UsagePath $usagePath -Now $now
    $burstObservation = Register-UsageFailure -Worker 'worker-burst' -ExitCode 1 -Stdout '' `
        -Stderr 'HTTP 429 Too Many Requests. Retry-After: 120' -UsagePath $usagePath -Now $now
    $ambiguousObservation = Register-UsageFailure -Worker 'worker-ambiguous' -ExitCode 1 -Stdout '' `
        -Stderr 'remote command ended unexpectedly' -UsagePath $usagePath -Now $now
    $authObservation = Register-UsageFailure -Worker 'worker-auth' -ExitCode 1 -Stdout '' `
        -Stderr 'HTTP 401 invalid API key' -UsagePath $usagePath -Now $now
    $quotaNoResetObservation = Register-UsageFailure -Worker 'worker-quota-no-reset' -ExitCode 1 -Stdout '' `
        -Stderr 'quota exhausted' -UsagePath $usagePath -Now $now

    $rows = @(Get-Content -LiteralPath $usagePath | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'register returns quota observation' ($quotaObservation.classification -eq 'quota_exhausted')
    Check 'register returns burst observation' ($burstObservation.classification -eq 'rate_limit_burst')
    Check 'register returns ambiguous observation' ($ambiguousObservation.classification -eq 'ambiguous')
    Check 'register returns auth observation' ($authObservation.classification -eq 'auth_config')
    Check 'register quota-no-reset is lockout not permanent' (
        $quotaNoResetObservation.classification -eq 'quota_exhausted' -and
        $null -ne $quotaNoResetObservation.reset_at -and
        [int]$quotaNoResetObservation.ttl -eq 21600)
    Check 'only journalable failures append rows' ($rows.Count -eq 4)
    $quotaRow = @($rows | Where-Object { $_.worker -eq 'worker-quota' })[0]
    $burstRow = @($rows | Where-Object { $_.worker -eq 'worker-burst' })[0]
    $ambiguousRow = @($rows | Where-Object { $_.worker -eq 'worker-ambiguous' })[0]
    $quotaNoResetRow = @($rows | Where-Object { $_.worker -eq 'worker-quota-no-reset' })[0]
    Check 'quota row is lockout' ($quotaRow.event -eq 'lockout')
    Check 'quota row carries source' ($quotaRow.source -eq 'error_classify')
    Check 'quota row carries reset_at' ((As-IsoString $quotaRow.reset_at) -eq '2099-01-01T00:00:00.0000000Z')
    Check 'burst row is cooldown' ($burstRow.event -eq 'cooldown')
    Check 'burst row carries until' ((As-IsoString $burstRow.until) -eq '2098-12-31T23:02:00.0000000Z')
    Check 'ambiguous row is only cooldown' ($ambiguousRow.event -eq 'cooldown')
    Check 'auth failure is not journal-locked' (@($rows | Where-Object { $_.worker -eq 'worker-auth' }).Count -eq 0)
    Check 'quota-no-reset journal has bounded reset_at' (
        $quotaNoResetRow.event -eq 'lockout' -and
        (As-IsoString $quotaNoResetRow.reset_at) -eq '2099-01-01T05:00:00.0000000Z' -and
        [int]$quotaNoResetRow.ttl -eq 21600)

    Add-UsageFailoverEvent -OriginalWorker 'worker-quota' -Substitute 'worker-peer' `
        -Reason 'quota_exhausted' -ResetAt $quotaObservation.reset_at -HadPartialDiff $true `
        -UsagePath $usagePath -Timestamp '2098-12-31T23:00:05.0000000Z'
    $hop = (Get-Content -LiteralPath $usagePath | Select-Object -Last 1) | ConvertFrom-Json
    Check 'hop row uses existing usage journal' ($hop.event -eq 'failover')
    Check 'hop row carries original worker' ($hop.original_worker -eq 'worker-quota')
    Check 'hop row carries substitute' ($hop.substitute -eq 'worker-peer')
    Check 'hop row carries reason' ($hop.reason -eq 'quota_exhausted')
    Check 'hop row carries reset' ((As-IsoString $hop.reset_at) -eq '2099-01-01T00:00:00.0000000Z')
    Check 'hop row carries partial-diff flag' ($hop.had_partial_diff -eq $true)
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failureCount -gt 0) {
    Write-Host "`n$($script:failureCount) FAILED"
    exit 1
}
Write-Host "`nALL PASS"
exit 0
