#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Proactive usage probe adapters and cache primitives (d090 Layer 2).
.DESCRIPTION
  Codex app-server is adapter #1. Every failure is fail-open: callers receive
  $null and dispatch policy remains unchanged. Successful raw responses are
  cached under BATON_HOME and normalized to the usage observation contract.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/usage-classify-lib.ps1"

function Get-BatonPluginVersion {
    $roots = [System.Collections.Generic.List[string]]::new()
    if ($env:CLAUDE_PLUGIN_ROOT) { [void]$roots.Add([string]$env:CLAUDE_PLUGIN_ROOT) }
    if ($env:BATON_REPO_ROOT) { [void]$roots.Add([string]$env:BATON_REPO_ROOT) }
    [void]$roots.Add((Split-Path $PSScriptRoot -Parent))
    foreach ($root in $roots) {
        try {
            $manifest = Join-Path $root '.claude-plugin/plugin.json'
            if (-not (Test-Path -LiteralPath $manifest)) { continue }
            $data = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$data.version)) { return [string]$data.version }
        } catch { }
    }
    return 'unknown'
}

function Wait-CodexJsonRpcResponse {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][int]$ResponseId,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    while ([datetime]::UtcNow -lt $DeadlineUtc) {
        $remainingMs = [int][math]::Max(1, [math]::Ceiling(($DeadlineUtc - [datetime]::UtcNow).TotalMilliseconds))
        $readTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remainingMs)) { return $null }
        $line = $readTask.Result
        if ($null -eq $line) { return $null }
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        try {
            $message = [string]$line | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $message.PSObject.Properties['id'] -and [int]$message.id -eq $ResponseId) {
                return $message
            }
        } catch {
            # app-server diagnostics or unrelated non-JSON lines are not responses.
        }
    }
    return $null
}

function Invoke-CodexRateLimitTransport {
    <# Start one app-server process, complete the initialize handshake, read rate
       limits, and always terminate the child. Any failure returns $null.
       -FileName/-ArgumentList are hermetic test seams; production keeps codex defaults. #>
    param(
        [Parameter(Mandatory)][string]$ClientVersion,
        [int]$TimeoutSeconds = 20,
        [string]$FileName = 'codex',
        [string[]]$ArgumentList
    )
    if ($TimeoutSeconds -le 0) { return $null }
    $exeArgs = if ($null -eq $ArgumentList -or @($ArgumentList).Count -eq 0) { @('app-server') } else { @($ArgumentList) }
    $process = $null
    $stderrTask = $null
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $FileName
        foreach ($exeArg in $exeArgs) {
            [void]$startInfo.ArgumentList.Add([string]$exeArg)
        }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
        $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { return $null }
        # Drain stderr asynchronously (pure .NET Task — no PS scriptblock on a
        # thread-pool thread) so a chatty app-server cannot fill the OS pipe and
        # stall the stdout handshake into the timeout. Payload is discarded.
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        $initializeRequest = [ordered]@{
            jsonrpc = '2.0'
            id = 1
            method = 'initialize'
            params = [ordered]@{
                clientInfo = [ordered]@{
                    name = 'baton'
                    title = 'Baton usage probe'
                    version = $ClientVersion
                }
            }
        }
        $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $initializeRequest -Depth 8 -Compress))
        $process.StandardInput.Flush()
        $initialized = Wait-CodexJsonRpcResponse -Process $process -ResponseId 1 -DeadlineUtc $deadline
        if ($null -eq $initialized -or $null -ne $initialized.PSObject.Properties['error'] -or
            $null -eq $initialized.PSObject.Properties['result']) { return $null }

        $initializedNotice = [ordered]@{ jsonrpc = '2.0'; method = 'initialized' }
        $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $initializedNotice -Depth 4 -Compress))
        $rateLimitRequest = [ordered]@{
            jsonrpc = '2.0'
            id = 2
            method = 'account/rateLimits/read'
            params = [ordered]@{}
        }
        $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $rateLimitRequest -Depth 6 -Compress))
        $process.StandardInput.Flush()
        $rateLimits = Wait-CodexJsonRpcResponse -Process $process -ResponseId 2 -DeadlineUtc $deadline
        if ($null -eq $rateLimits -or $null -ne $rateLimits.PSObject.Properties['error']) { return $null }
        return $rateLimits
    } catch {
        return $null
    } finally {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) { $process.Kill($true) }
            } catch { }
            if ($null -ne $stderrTask) {
                try { [void]$stderrTask.Wait(500) } catch { }
            }
            try { $process.Dispose() } catch { }
        }
    }
}

function ConvertFrom-CodexRateLimitResponse {
    <# Normalize app-server primary/secondary windows to spec section 3.1.
       Unknown durations and malformed values are ignored; no valid windows -> null. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)]$Response,
        [datetimeoffset]$ObservedAt = [datetimeoffset]::UtcNow,
        [int]$TtlSeconds = 600
    )
    if ($TtlSeconds -le 0 -or $null -eq $Response -or $Response -is [string]) { return $null }
    if ($null -eq $Response.PSObject.Properties['id'] -or [int]$Response.id -ne 2) { return $null }
    if ($null -ne $Response.PSObject.Properties['error'] -or $null -eq $Response.PSObject.Properties['result']) { return $null }
    $rateLimits = $Response.result.rateLimits
    if ($null -eq $rateLimits) { return $null }

    $rows = [System.Collections.ArrayList]@()
    foreach ($windowName in @('primary', 'secondary')) {
        $window = $rateLimits.$windowName
        if ($null -eq $window) { continue }
        $duration = 0
        if (-not [int]::TryParse([string]$window.windowDurationMins, [ref]$duration)) { continue }
        $scope = if ($duration -eq 300) { 'five_hour' }
                 elseif ($duration -eq 10080) { 'weekly' }
                 else { $null }
        if (-not $scope) { continue }

        $used = [double]0
        if (-not [double]::TryParse(
                [string]$window.usedPercent,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$used) -or
            -not [double]::IsFinite($used) -or $used -lt 0 -or $used -gt 100) { continue }
        $resetEpoch = [long]0
        if (-not [long]::TryParse([string]$window.resetsAt, [ref]$resetEpoch) -or $resetEpoch -le 0) { continue }
        try { $resetInstant = [datetimeoffset]::FromUnixTimeSeconds($resetEpoch) }
        catch { continue }

        [void]$rows.Add([ordered]@{
            worker = $Worker
            scope = $scope
            used_pct = $used
            reset_at = $resetInstant.ToString('o')
            source = 'app_server_probe'
            observed_at = $ObservedAt.ToString('o')
            ttl = $TtlSeconds
            confidence = [double]0.95
        })
    }
    if ($rows.Count -eq 0) { return $null }
    return ,([object[]]$rows.ToArray())
}

function Add-UsageProbeCacheRow {
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)][object[]]$Observations,
        [string]$CachePath = (Join-Path (Get-BatonHome) 'usage-probe-cache.jsonl'),
        [datetimeoffset]$ObservedAt = [datetimeoffset]::UtcNow,
        [int]$TtlSeconds = 600
    )
    if ($TtlSeconds -le 0 -or @($Observations).Count -eq 0) { return }
    try {
        $parent = Split-Path -Parent $CachePath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $row = [ordered]@{
            worker = $Worker
            observed_at = $ObservedAt.ToString('o')
            ttl = $TtlSeconds
            raw = $Raw
            observations = @($Observations)
        }
        $json = ConvertTo-Json -InputObject $row -Depth 20 -Compress
        Add-Content -LiteralPath $CachePath -Value $json -Encoding utf8NoBOM
    } catch {
        # Cache is advisory. A write failure must not affect dispatch.
    }
}

function Get-FreshUsageProbeCache {
    param(
        [Parameter(Mandatory)][string]$Worker,
        [string]$CachePath = (Join-Path (Get-BatonHome) 'usage-probe-cache.jsonl'),
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )
    if (-not (Test-Path -LiteralPath $CachePath)) { return $null }
    $latest = $null
    $latestAt = [datetimeoffset]::MinValue
    foreach ($line in (Get-Content -LiteralPath $CachePath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        try {
            $row = [string]$line | ConvertFrom-Json -ErrorAction Stop
            if ([string]$row.worker -ne $Worker) { continue }
            $rowAt = [datetimeoffset]::MinValue
            $rowTtl = 0
            if (-not [datetimeoffset]::TryParse([string]$row.observed_at, [ref]$rowAt)) { continue }
            if (-not [int]::TryParse([string]$row.ttl, [ref]$rowTtl) -or $rowTtl -le 0) { continue }
            if ($null -eq $row.raw -or @($row.observations).Count -eq 0) { continue }
            if ($rowAt -gt $latestAt) { $latest = $row; $latestAt = $rowAt }
        } catch { }
    }
    if ($null -eq $latest) { return $null }
    if ($Now -ge $latestAt.AddSeconds([int]$latest.ttl)) { return $null }
    return $latest
}

function Get-CodexUsageProbe {
    <# Return a fresh cached or newly probed snapshot. The optional Transport seam
       has contract (& transport <clientVersion> <timeoutSeconds>) -> id-2 response. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [scriptblock]$Transport,
        [string]$CachePath = (Join-Path (Get-BatonHome) 'usage-probe-cache.jsonl'),
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
        [int]$TimeoutSeconds = 20,
        [int]$TtlSeconds = 600
    )
    if ($TimeoutSeconds -le 0 -or $TtlSeconds -le 0) { return $null }
    $cached = Get-FreshUsageProbeCache -Worker $Worker -CachePath $CachePath -Now $Now
    if ($null -ne $cached) {
        return [ordered]@{
            raw = $cached.raw
            observations = @($cached.observations)
            observed_at = [string]$cached.observed_at
            ttl = [int]$cached.ttl
            cached = $true
        }
    }

    try {
        $version = Get-BatonPluginVersion
        $response = if ($Transport) { & $Transport $version $TimeoutSeconds }
                    else { Invoke-CodexRateLimitTransport -ClientVersion $version -TimeoutSeconds $TimeoutSeconds }
        $observations = ConvertFrom-CodexRateLimitResponse -Worker $Worker -Response $response `
            -ObservedAt $Now -TtlSeconds $TtlSeconds
        if ($null -eq $observations -or @($observations).Count -eq 0) { return $null }
        Add-UsageProbeCacheRow -Worker $Worker -Raw $response -Observations @($observations) `
            -CachePath $CachePath -ObservedAt $Now -TtlSeconds $TtlSeconds
        return [ordered]@{
            raw = $response
            observations = @($observations)
            observed_at = $Now.ToString('o')
            ttl = $TtlSeconds
            cached = $false
        }
    } catch {
        return $null
    }
}

function Get-UsageProbeCapDecision {
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][object[]]$Observations
    )
    $checked = [System.Collections.ArrayList]@()
    $crossings = [System.Collections.ArrayList]@()
    $policy = $Provider.usage_policy
    if ($null -eq $policy) { return [ordered]@{ over_cap = $false; checked = @(); windows = @() } }
    foreach ($observation in @($Observations)) {
        $knob = if ([string]$observation.scope -eq 'five_hour') { 'soft_cap_5h' }
                elseif ([string]$observation.scope -eq 'weekly') { 'soft_cap_weekly' }
                else { $null }
        if (-not $knob -or $null -eq $policy[$knob]) { continue }
        $used = [double]$observation.used_pct
        $cap = [double]$policy[$knob]
        $windowDecision = [ordered]@{
            window = [string]$observation.scope
            used_pct = $used
            cap = $cap
            policy_knob = $knob
            reset_at = [string]$observation.reset_at
            source = [string]$observation.source
            observed_at = [string]$observation.observed_at
            ttl = [int]$observation.ttl
            confidence = [double]$observation.confidence
        }
        [void]$checked.Add($windowDecision)
        if ($used -ge $cap) { [void]$crossings.Add($windowDecision) }
    }
    return [ordered]@{
        over_cap = ($crossings.Count -gt 0)
        checked = @($checked.ToArray())
        windows = @($crossings.ToArray())
    }
}

function Get-FleetMedianDispatchTokens {
    <# Fold the latest N fleet journal token fields for one provider. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)][string]$JournalPath,
        [int]$SampleSize = 20
    )
    $empty = [ordered]@{ worker = $Worker; count = 0; median = [double]0; total = [double]0 }
    if ($SampleSize -le 0 -or -not (Test-Path -LiteralPath $JournalPath)) { return $empty }
    $values = [System.Collections.Generic.List[double]]::new()
    foreach ($journalLine in (Get-Content -LiteralPath $JournalPath -ErrorAction SilentlyContinue)) {
        $fields = @([string]$journalLine -split '\s*\|\s*')
        if ($fields.Count -lt 3 -or $fields[1] -ne 'fleet' -or $fields[2] -ne $Worker) { continue }
        $tokenMatch = [regex]::Match(
            [string]$journalLine,
            '\|\s*tok:(?<tokens>\d+)\((?:exact|estimate)\)\s*$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase,
            [timespan]::FromMilliseconds(100))
        if (-not $tokenMatch.Success) { continue }
        $tokenValue = [long]0
        if ([long]::TryParse($tokenMatch.Groups['tokens'].Value, [ref]$tokenValue) -and $tokenValue -ge 0) {
            $values.Add([double]$tokenValue)
        }
    }
    if ($values.Count -eq 0) { return $empty }
    $recent = @($values | Select-Object -Last $SampleSize | Sort-Object)
    $count = $recent.Count
    $median = if (($count % 2) -eq 1) { [double]$recent[[int][math]::Floor($count / 2)] }
              else { ([double]$recent[($count / 2) - 1] + [double]$recent[$count / 2]) / 2 }
    $total = [double](($recent | Measure-Object -Sum).Sum)
    return [ordered]@{ worker = $Worker; count = $count; median = $median; total = $total }
}

function Get-UsageFitAdvisory {
    <# Observe-only approximation: scale the median dispatch's share of the recent
       token sample by current used_pct, then compare it with remaining percent. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)]$Observation,
        [Parameter(Mandatory)]$TokenStats
    )
    $count = [int]$TokenStats.count
    $median = [double]$TokenStats.median
    $total = [double]$TokenStats.total
    $used = [double]$Observation.used_pct
    if ($count -le 0 -or $median -le 0 -or $total -le 0 -or $used -le 0) { return $null }
    $remaining = [math]::Max(0, 100 - $used)
    $typicalShare = ($median / $total) * $used
    if (-not [double]::IsFinite($typicalShare) -or $remaining -ge $typicalShare) { return $null }
    $windowLabel = if ([string]$Observation.scope -eq 'five_hour') { '5h' }
                   elseif ([string]$Observation.scope -eq 'weekly') { 'weekly' }
                   else { [string]$Observation.scope }
    $usedText = [math]::Round($used, 1)
    $medianText = [int][math]::Round($median)
    return "$Worker at $usedText% of $windowLabel; typical dispatch burns ~$medianText tok - consider holding"
}

function Get-MonthlyUsagePaceAdvisory {
    <# Observe-only pace check over an already-journaled billing observation.
       Adapter #3 produces the observation later; this helper never fetches billing. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)][hashtable]$UsagePolicy,
        [object[]]$Rows = @(),
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )
    $result = [ordered]@{
        status = 'unavailable'; advisory = $false; line = $null
        consumed = $null; expected = $null; allowance = $null
    }
    if (-not $UsagePolicy.ContainsKey('monthly_allowance')) { return $result }
    $allowance = [double]$UsagePolicy.monthly_allowance
    if ($allowance -le 0 -or -not [double]::IsFinite($allowance)) { return $result }
    $latest = @($Rows | Where-Object {
        [string]$_.worker -eq $Worker -and [string]$_.scope -eq 'paid_credit' -and
        [string]$_.source -eq 'billing_api' -and $null -ne $_.consumed -and $_.reset_at
    } | Sort-Object {
        try { [datetimeoffset]::Parse([string]$_.observed_at) } catch { [datetimeoffset]::MinValue }
    } | Select-Object -Last 1)
    if ($latest.Count -eq 0) { return $result }
    $observation = $latest[0]
    $consumed = [double]$observation.consumed
    if ($consumed -lt 0 -or -not [double]::IsFinite($consumed)) { return $result }
    try { $reset = [datetimeoffset]::Parse([string]$observation.reset_at) }
    catch { return $result }
    $cycleStart = $reset.AddMonths(-1)
    $cycleSeconds = ($reset - $cycleStart).TotalSeconds
    $elapsedSeconds = ($Now - $cycleStart).TotalSeconds
    if ($cycleSeconds -le 0 -or $elapsedSeconds -lt 0 -or $Now -ge $reset) { return $result }
    $elapsedFraction = [math]::Min([double]1, [double]($elapsedSeconds / $cycleSeconds))
    $expected = $allowance * $elapsedFraction
    $result.status = 'ok'
    $result.consumed = $consumed
    $result.expected = [math]::Round($expected, 2)
    $result.allowance = $allowance
    if ($consumed -gt $expected) {
        $result.advisory = $true
        $result.line = "$Worker monthly usage pace is ahead of the current cycle - advisory only"
    }
    return $result
}

function Test-UsageSurplusSpend {
    <# Small, cache-only preference for adapter-backed subscription CLI capacity
       that would otherwise expire within 24 hours. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        $Snapshot,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )
    $result = [ordered]@{ apply = $false; preference = [double]0; reason = '' }
    if ($null -eq $Provider.usage_policy -or $Provider.usage_policy.probe -ne $true) { return $result }
    if ([string]$Provider.kind -ne 'cli' -or [string]$Provider.platform -ne 'codex') { return $result }
    if ($null -eq $Snapshot) { return $result }
    try {
        $snapshotAt = [datetimeoffset]::Parse([string]$Snapshot.observed_at)
        $snapshotTtl = [int]$Snapshot.ttl
        if ($snapshotTtl -le 0 -or $Now -ge $snapshotAt.AddSeconds($snapshotTtl)) { return $result }
    } catch { return $result }
    $weekly = @($Snapshot.observations | Where-Object {
        [string]$_.scope -eq 'weekly' -and [string]$_.source -eq 'app_server_probe'
    } | Select-Object -First 1)
    if ($weekly.Count -eq 0) { return $result }
    try { $reset = [datetimeoffset]::Parse([string]$weekly[0].reset_at) }
    catch { return $result }
    $untilReset = $reset - $Now
    if ($untilReset.TotalSeconds -le 0 -or $untilReset.TotalHours -gt 24) { return $result }
    # Headroom gate: used must stay below (soft_cap_weekly - 20). Clamp so a
    # mis-tiny soft_cap_weekly cannot invert the inequality into always-apply.
    $threshold = [math]::Max([double]0, [double]$Provider.usage_policy.soft_cap_weekly - 20)
    if ([double]$weekly[0].used_pct -ge $threshold) { return $result }
    $result.apply = $true
    # Near-tie breaker only: economy score = tier_rank - quality*0.001, so a
    # quality gap of 0.01 is 1e-5 on the score scale. 1e-7 can never flip a
    # real quality difference; it only breaks equal-score ties.
    $result.preference = [double]1e-7
    $result.reason = 'surplus_spend'
    return $result
}

function Add-UsageProbeLimitedRows {
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)]$Decision,
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl')
    )
    foreach ($window in @($Decision.windows)) {
        $row = [ordered]@{
            ts = [string]$window.observed_at
            event = 'limited'
            worker = $Worker
            scope = [string]$window.window
            window = [string]$window.window
            used_pct = [double]$window.used_pct
            cap = [double]$window.cap
            policy_knob = [string]$window.policy_knob
            reset_at = [string]$window.reset_at
            source = 'app_server_probe'
            observed_at = [string]$window.observed_at
            ttl = [int]$window.ttl
            confidence = [double]$window.confidence
            reason = "preflight soft cap reached ($($window.policy_knob))"
        }
        Add-UsageClassifyJournalRow -Row $row -UsagePath $UsagePath
    }
}

function Get-UsageWindowDecisionList {
    <# Normalize one window object or an array of crossings. Hashtables must not
       be unrolled via @() (dictionary key enumeration). #>
    param($WindowDecision)
    if ($null -eq $WindowDecision) { return ,[object[]]@() }
    if ($WindowDecision -is [System.Array]) { return ,[object[]]@($WindowDecision) }
    if ($WindowDecision -is [System.Collections.IList] -and
        $WindowDecision -isnot [string] -and
        $WindowDecision -isnot [System.Collections.IDictionary]) {
        return ,[object[]]@($WindowDecision)
    }
    return ,[object[]](, $WindowDecision)
}

function Add-UsagePreflightEvent {
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)][ValidateSet('dispatched','rerouted','held')][string]$Outcome,
        $WindowDecision,
        [string]$Substitute,
        [string]$Reason,
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl'),
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = [datetimeoffset]::UtcNow.ToString('o') }
    $row = [ordered]@{
        ts = $Timestamp
        event = 'preflight'
        worker = $Worker
        outcome = $Outcome
        source = 'app_server_probe'
    }
    if ($WindowDecision) {
        # Accept one window object or an array of crossings; name every window.
        $windowList = Get-UsageWindowDecisionList -WindowDecision $WindowDecision
        $primary = $windowList[0]
        $windowNames = [string[]]@($windowList | ForEach-Object { [string]$_.window })
        $row.window = if ($windowNames.Count -le 1) { [string]$primary.window } else { ($windowNames -join ',') }
        $row.windows = $windowNames
        $row.used_pct = [double]$primary.used_pct
        $row.cap = [double]$primary.cap
        $row.policy_knob = if ($windowList.Count -le 1) {
            [string]$primary.policy_knob
        } else {
            (([string[]]@($windowList | ForEach-Object { [string]$_.policy_knob })) -join ',')
        }
        $row.reset_at = [string]$primary.reset_at
    }
    if ($Substitute) { $row.substitute = $Substitute }
    if ($Reason) { $row.reason = $Reason }
    Add-UsageClassifyJournalRow -Row $row -UsagePath $UsagePath
}

function Format-UsagePreflightLine {
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)]$WindowDecision,
        [Parameter(Mandatory)][ValidateSet('rerouted','held')][string]$Outcome,
        [string]$Substitute,
        [string]$AlsoOverCap
    )
    $windowList = Get-UsageWindowDecisionList -WindowDecision $WindowDecision
    $evidenceParts = foreach ($wd in $windowList) {
        $used = [math]::Round([double]$wd.used_pct, 1)
        $cap = [math]::Round([double]$wd.cap, 1)
        "at $used% of $($wd.window) (resets $($wd.reset_at)), reached $($wd.policy_knob)=$cap"
    }
    $evidence = ($evidenceParts -join '; ')
    $line = "usage preflight: $Worker is $evidence"
    if ($Outcome -eq 'rerouted') { return "$line; rerouting to $Substitute" }
    if ($AlsoOverCap) {
        return "$line; $AlsoOverCap also over soft cap; held (no further hop)"
    }
    return "$line; no peer available + $Worker over soft cap"
}
