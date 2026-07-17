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
       limits, and always terminate the child. Any failure returns $null. #>
    param(
        [Parameter(Mandatory)][string]$ClientVersion,
        [int]$TimeoutSeconds = 20
    )
    if ($TimeoutSeconds -le 0) { return $null }
    $process = $null
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'codex'
        [void]$startInfo.ArgumentList.Add('app-server')
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
