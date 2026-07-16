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
    Check "$($case.name): confidence bounded" ([double]$observation.confidence -gt 0 -and [double]$observation.confidence -le 1)
}

$success = Get-UsageFailureObservation -ExitCode 0 -Stdout 'normal response' -Stderr '' -Now $now
Check 'successful dispatch has no journal event' ($null -eq $success.event)
Check 'successful dispatch does not fail over' (-not $success.hard_failover)

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

    $rows = @(Get-Content -LiteralPath $usagePath | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'register returns quota observation' ($quotaObservation.classification -eq 'quota_exhausted')
    Check 'register returns burst observation' ($burstObservation.classification -eq 'rate_limit_burst')
    Check 'register returns ambiguous observation' ($ambiguousObservation.classification -eq 'ambiguous')
    Check 'register returns auth observation' ($authObservation.classification -eq 'auth_config')
    Check 'only journalable failures append rows' ($rows.Count -eq 3)
    $quotaRow = @($rows | Where-Object { $_.worker -eq 'worker-quota' })[0]
    $burstRow = @($rows | Where-Object { $_.worker -eq 'worker-burst' })[0]
    $ambiguousRow = @($rows | Where-Object { $_.worker -eq 'worker-ambiguous' })[0]
    Check 'quota row is lockout' ($quotaRow.event -eq 'lockout')
    Check 'quota row carries source' ($quotaRow.source -eq 'error_classify')
    Check 'quota row carries reset_at' ((As-IsoString $quotaRow.reset_at) -eq '2099-01-01T00:00:00.0000000Z')
    Check 'burst row is cooldown' ($burstRow.event -eq 'cooldown')
    Check 'burst row carries until' ((As-IsoString $burstRow.until) -eq '2098-12-31T23:02:00.0000000Z')
    Check 'ambiguous row is only cooldown' ($ambiguousRow.event -eq 'cooldown')
    Check 'auth failure is not journal-locked' (@($rows | Where-Object { $_.worker -eq 'worker-auth' }).Count -eq 0)

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
