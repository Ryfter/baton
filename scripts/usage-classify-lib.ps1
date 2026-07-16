#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Reactive provider-limit classifier for Usage Governor observations.
.DESCRIPTION
  Normalizes a fleet dispatch's exit code and output, then appends compatible
  rows to the existing usage-journal.jsonl. It does not select substitutes.
#>
. "$PSScriptRoot/baton-home.ps1"

$script:DefaultClassifyUsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl')

function Find-UsageRegexMatch {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern
    )
    try {
        $expression = [regex]::new(
            $Pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase,
            [timespan]::FromMilliseconds(100))
        return $expression.Match($Text)
    } catch {
        return [System.Text.RegularExpressions.Match]::Empty
    }
}

function ConvertTo-ClassifiedResetAt {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][datetime]$Now,
        [int]$DefaultSeconds = 0
    )
    $nowUtc = $Now.ToUniversalTime()
    $isoMatch = Find-UsageRegexMatch -Text $Text -Pattern '(?<iso>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2}))'
    if ($isoMatch.Success) {
        $parsed = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse(
                $isoMatch.Groups['iso'].Value,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$parsed)) {
            return $parsed.UtcDateTime.ToString('o')
        }
    }

    $retryAfterMatch = Find-UsageRegexMatch -Text $Text -Pattern 'retry[ -]?after\s*:?\s*(?<seconds>\d+)'
    if ($retryAfterMatch.Success) {
        $seconds = 0
        if ([int]::TryParse($retryAfterMatch.Groups['seconds'].Value, [ref]$seconds) -and $seconds -gt 0) {
            return $nowUtc.AddSeconds($seconds).ToString('o')
        }
    }

    $retryDateMatch = Find-UsageRegexMatch -Text $Text -Pattern 'retry[ -]?after\s*:\s*(?<date>[^\r\n]+)'
    if ($retryDateMatch.Success) {
        $retryDate = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse(
                $retryDateMatch.Groups['date'].Value.Trim(),
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$retryDate)) {
            return $retryDate.UtcDateTime.ToString('o')
        }
    }

    # Zone-less wall clocks (e.g. "try again at 01:30") are host LOCAL time
    # (DateTimeStyles.AssumeLocal). Emit ISO-8601 WITH an explicit offset so the
    # absolute instant is unambiguous; do not silently re-label local as Z/UTC.
    $clockMatch = Find-UsageRegexMatch -Text $Text -Pattern '(?:resets?|retry|try again)\s+(?:at\s+)?(?<clock>\d{1,2}:\d{2}\s*(?:AM|PM)?\s*(?:UTC|GMT)?)\b'
    if ($clockMatch.Success) {
        $clockText = $clockMatch.Groups['clock'].Value.Trim()
        $clockHasZone = $clockText.EndsWith('UTC', [System.StringComparison]::OrdinalIgnoreCase) -or
            $clockText.EndsWith('GMT', [System.StringComparison]::OrdinalIgnoreCase)
        if ($clockHasZone) {
            $clockText = $clockText.Substring(0, $clockText.Length - 3).TrimEnd() + ' +00:00'
            $clockStyle = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
            $dayBase = $nowUtc.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        } else {
            $clockStyle = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor
                [System.Globalization.DateTimeStyles]::AssumeLocal
            $nowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, [System.TimeZoneInfo]::Local)
            $dayBase = $nowLocal.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $clockInstant = [datetimeoffset]::MinValue
        $datedClock = $dayBase + ' ' + $clockText
        if ([datetimeoffset]::TryParse(
                $datedClock,
                [System.Globalization.CultureInfo]::InvariantCulture,
                $clockStyle,
                [ref]$clockInstant)) {
            if ($clockInstant.UtcDateTime -le $nowUtc) { $clockInstant = $clockInstant.AddDays(1) }
            if ($clockHasZone) { return $clockInstant.UtcDateTime.ToString('o') }
            # Zone-less: keep offset in the emitted string (deterministic given host TZ + -Now).
            return $clockInstant.ToString('o')
        }
    }

    $relativeMatch = Find-UsageRegexMatch -Text $Text -Pattern '(?:resets?|retry|try again)\s+(?:at|in|after)\s+(?<amount>\d+)\s*(?<unit>seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d)\b'
    if ($relativeMatch.Success) {
        $amount = 0
        if ([int]::TryParse($relativeMatch.Groups['amount'].Value, [ref]$amount) -and $amount -gt 0) {
            $unit = $relativeMatch.Groups['unit'].Value.ToLowerInvariant()
            $span = if ($unit.StartsWith('d')) { [timespan]::FromDays($amount) }
                    elseif ($unit.StartsWith('h')) { [timespan]::FromHours($amount) }
                    elseif ($unit.StartsWith('m')) { [timespan]::FromMinutes($amount) }
                    else { [timespan]::FromSeconds($amount) }
            return ($nowUtc + $span).ToString('o')
        }
    }

    if ($DefaultSeconds -gt 0) { return $nowUtc.AddSeconds($DefaultSeconds).ToString('o') }
    return $null
}

function Get-UsageFailureObservation {
    <# Return the normalized section-3.1 observation plus reactive classification. #>
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Stdout = '',
        [AllowEmptyString()][string]$Stderr = '',
        [datetime]$Now = [datetime]::UtcNow
    )
    $nowUtc = $Now.ToUniversalTime()
    $text = (([string]$Stdout) + "`n" + ([string]$Stderr)).Trim()
    $classification = 'ambiguous'
    $eventKind = $null
    $hardFailover = $false
    $scope = 'api_rate'
    $confidence = 0.2
    $defaultSeconds = 0
    $reason = if ($ExitCode -eq 0) { 'dispatch_succeeded' } else { 'unrecognized_dispatch_failure' }

    if ($ExitCode -ne 0) {
        # Auth/config hard-excludes failover/lockout even when quota phrases co-occur.
        # Quota: real provider limit phrasings only — bare "hit your limit of N retries"
        # must stay ambiguous (negative lookahead on "of <digits>").
        # Burst: 429 / rate-limit / rate_limit_error only — bare "retry after" is a
        # reset-time parse source, not a standalone burst trigger.
        $authPattern = '\b(?:401|403)\b|unauthori[sz]ed|invalid\s+(?:api\s+)?key|authentication\s+(?:required|failed)|login\s+required|configuration\s+error|unknown\s+model|model\s+not\s+found'
        $quotaPattern = 'weekly\s+(?:usage\s+)?limit|hit\s+your\s+limit(?!\s+of\s+\d)|hit\s+(?:your|the)\s+(?:usage|weekly|session|model|opus)[^\r\n]{0,60}\blimit|usage\s+limit\s+(?:reached|exceeded)|quota\s+(?:exhausted|exceeded)|insufficient_quota|billing\s+hard\s+limit|credits?\s+exhausted'
        $burstPattern = '\b429\b|too\s+many\s+requests|rate[_ -]?limit(?:ed|_error)?(?:\s+(?:exceeded|reached))?'
        $overloadPattern = '\b(?:500|502|503|529)\b|overloaded(?:_error)?|server\s+is\s+overloaded|service\s+unavailable|temporarily\s+at\s+capacity'

        if ((Find-UsageRegexMatch -Text $text -Pattern $authPattern).Success) {
            $classification = 'auth_config'
            $scope = 'subscription'
            $confidence = 0.95
            $reason = 'provider authentication or configuration failure'
        }
        elseif ((Find-UsageRegexMatch -Text $text -Pattern $quotaPattern).Success) {
            $classification = 'quota_exhausted'
            $eventKind = 'lockout'
            $hardFailover = $true
            $scope = if ((Find-UsageRegexMatch -Text $text -Pattern '\bweekly\b').Success) { 'weekly' }
                     elseif ((Find-UsageRegexMatch -Text $text -Pattern '\b(?:model|opus)\b').Success) { 'model' }
                     else { 'subscription' }
            $confidence = 0.95
            $reason = 'provider quota exhausted'
            # No parseable reset_at -> bounded lockout TTL (not permanent-until-manual-clear).
            # subscription/weekly: 6h; model (and other non-weekly scopes): 1h.
            $defaultSeconds = if ($scope -in @('subscription', 'weekly')) { 6 * 3600 } else { 3600 }
        }
        elseif ((Find-UsageRegexMatch -Text $text -Pattern $burstPattern).Success) {
            $classification = 'rate_limit_burst'
            $eventKind = 'cooldown'
            $hardFailover = $true
            $confidence = 0.9
            $defaultSeconds = 900
            $reason = 'temporary provider rate limit'
        }
        elseif ((Find-UsageRegexMatch -Text $text -Pattern $overloadPattern).Success) {
            $classification = 'server_overload'
            $eventKind = 'cooldown'
            $confidence = 0.85
            $defaultSeconds = 900
            $reason = 'provider server overloaded'
        }
        else {
            $eventKind = 'cooldown'
            $defaultSeconds = 300
        }
    }

    $resetAt = ConvertTo-ClassifiedResetAt -Text $text -Now $nowUtc -DefaultSeconds $defaultSeconds
    $ttl = if ($resetAt) {
        try {
            $resetTime = [datetimeoffset]::Parse($resetAt).UtcDateTime
            $seconds = ($resetTime - $nowUtc).TotalSeconds
            if (-not [double]::IsFinite($seconds)) {
                [math]::Max(1, $defaultSeconds)
            } else {
                # Guard overflow: clamp into int range before cast.
                $ceiling = [math]::Ceiling($seconds)
                if ($ceiling -gt [int]::MaxValue) { [int]::MaxValue }
                elseif ($ceiling -lt 1) { 1 }
                else { [int]$ceiling }
            }
        } catch { [math]::Max(1, $defaultSeconds) }
    } else { [math]::Max(1, $(if ($defaultSeconds -gt 0) { $defaultSeconds } else { 3600 })) }

    return [ordered]@{
        classification = $classification
        event = $eventKind
        hard_failover = $hardFailover
        scope = $scope
        used_pct = $null
        reset_at = $resetAt
        source = 'error_classify'
        observed_at = $nowUtc.ToString('o')
        ttl = $ttl
        confidence = $confidence
        reason = $reason
    }
}

function Add-UsageClassifyJournalRow {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Row,
        [string]$UsagePath = $script:DefaultClassifyUsagePath
    )
    try {
        $parent = Split-Path -Parent $UsagePath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $json = $Row | ConvertTo-Json -Depth 6 -Compress
        Add-Content -LiteralPath $UsagePath -Value $json -Encoding utf8NoBOM
    } catch {
        Write-Warning "usage: failed to append classified event to $UsagePath : $($_.Exception.Message)"
    }
}

function Register-UsageFailure {
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Stdout = '',
        [AllowEmptyString()][string]$Stderr = '',
        [string]$UsagePath = $script:DefaultClassifyUsagePath,
        [datetime]$Now = [datetime]::UtcNow
    )
    $observation = Get-UsageFailureObservation -ExitCode $ExitCode -Stdout $Stdout -Stderr $Stderr -Now $Now
    if ($observation.event) {
        $row = [ordered]@{
            ts = $observation.observed_at
            event = $observation.event
            worker = $Worker
            scope = $observation.scope
            used_pct = $observation.used_pct
            reset_at = $observation.reset_at
            source = $observation.source
            observed_at = $observation.observed_at
            ttl = $observation.ttl
            confidence = $observation.confidence
            reason = $observation.reason
            classification = $observation.classification
        }
        if ($observation.event -eq 'cooldown') { $row.until = $observation.reset_at }
        Add-UsageClassifyJournalRow -Row $row -UsagePath $UsagePath
    }
    return $observation
}

function Add-UsageFailoverEvent {
    param(
        [Parameter(Mandatory)][string]$OriginalWorker,
        [Parameter(Mandatory)][string]$Substitute,
        [Parameter(Mandatory)][string]$Reason,
        [string]$ResetAt,
        [Parameter(Mandatory)][bool]$HadPartialDiff,
        [string]$UsagePath = $script:DefaultClassifyUsagePath,
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = [datetime]::UtcNow.ToString('o') }
    $row = [ordered]@{
        ts = $Timestamp
        event = 'failover'
        worker = $OriginalWorker
        original_worker = $OriginalWorker
        substitute = $Substitute
        reason = $Reason
        reset_at = $ResetAt
        had_partial_diff = $HadPartialDiff
        source = 'error_classify'
    }
    Add-UsageClassifyJournalRow -Row $row -UsagePath $UsagePath
}
