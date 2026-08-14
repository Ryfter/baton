#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Proactive usage probe adapters and cache primitives (d090 Layer 2).
.DESCRIPTION
  Codex app-server is adapter #1. Every failure is fail-open: callers receive
  $null and dispatch policy remains unchanged. Successful raw responses are
  cached under BATON_HOME and normalized to the usage observation contract.

  #173: which adapter runs is resolved by TRANSPORT NAME through the registry
  below, never by hardcoded platform. A provider whose transport does not
  resolve is simply not probed (fail closed) and still dispatches normally.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/usage-classify-lib.ps1"
# Authenticated-HTTP probes borrow Resolve-FleetHttpAuth from fleet-lib. Guarded
# so the two libraries can be dot-sourced in either order without one clobbering
# the other's definitions; fleet-lib does not source this file, so no cycle.
if (-not (Get-Command -Name 'Resolve-FleetHttpAuth' -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot/fleet-lib.ps1"
}

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

function Get-ProbeObjectField {
    <# Read one field off either a hashtable or a PSCustomObject without throwing.
       Probe payloads arrive as hashtables in-process and as PSCustomObjects after
       a JSON round-trip through the cache; both must read the same. #>
    param($InputObject, [Parameter(Mandatory)][string]$Field)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Field)) { return $InputObject[$Field] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Field]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-CodexBarBinaryPath {
    <# Binary resolution order: an explicit usage_policy.probe_command, then
       codexbar-cli on PATH, then the default Windows install location built from
       LOCALAPPDATA. No absolute user path is ever hardcoded in the repo. Returns
       $null when nothing resolves — the caller then probes nothing. #>
    param([string]$ProbeCommand)
    if (-not [string]::IsNullOrWhiteSpace($ProbeCommand)) { return $ProbeCommand.Trim() }
    try {
        $onPath = @(Get-Command 'codexbar-cli' -CommandType Application -ErrorAction SilentlyContinue) |
            Select-Object -First 1
        if ($null -ne $onPath -and -not [string]::IsNullOrWhiteSpace([string]$onPath.Source)) {
            return [string]$onPath.Source
        }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
        $installed = Join-Path ([string]$env:LOCALAPPDATA) 'Programs/CodexBar/codexbar-cli.exe'
        if (Test-Path -LiteralPath $installed) { return $installed }
    }
    return $null
}

function Invoke-CodexBarUsageProcess {
    <# Run one child process to completion under a deadline, capturing stdout,
       stderr, exit code and duration. Both pipes are drained asynchronously so a
       chatty child cannot deadlock on a full OS buffer. Any failure -> $null. #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSeconds = 20
    )
    if ($TimeoutSeconds -le 0) { return $null }
    $process = $null
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $FilePath
        foreach ($exeArg in $ArgumentList) { [void]$startInfo.ArgumentList.Add([string]$exeArg) }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $startedAt = [datetime]::UtcNow
        if (-not $process.Start()) { return $null }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            return $null
        }
        [void]$stdoutTask.Wait(2000)
        [void]$stderrTask.Wait(2000)
        return [ordered]@{
            exit_code = [int]$process.ExitCode
            stdout = if ($stdoutTask.IsCompletedSuccessfully) { [string]$stdoutTask.Result } else { '' }
            stderr = if ($stderrTask.IsCompletedSuccessfully) { [string]$stderrTask.Result } else { '' }
            duration_ms = [int]([datetime]::UtcNow - $startedAt).TotalMilliseconds
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
            try { $process.Dispose() } catch { }
        }
    }
}

function Invoke-CodexBarUsageTransport {
    <# Adapter #2: shell out to the local codexbar-cli and read what it reports.
       Fail-soft on OBSERVATION — a missing binary, a non-zero exit, or unparseable
       stdout all return $null and the caller dispatches unprobed; nothing throws.
       Fail-closed on IDENTITY — with no -ProbeProvider nothing is launched at all,
       because guessing which account is being queried is worse than not knowing.
       -Runner is the hermetic test seam: (& $Runner <file> <args[]> <timeout>) ->
       @{ exit_code; stdout; stderr; duration_ms }. Tests never touch the binary. #>
    param(
        [string]$ProbeProvider,
        [int]$TimeoutSeconds = 20,
        [string]$ProbeCommand,
        [scriptblock]$Runner
    )
    if ($TimeoutSeconds -le 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($ProbeProvider)) { return $null }
    $probeProviderName = $ProbeProvider.Trim()
    # Shape guard only — the set of provider names belongs to the tool, not to us,
    # so nothing here enumerates them. Arguments go through ArgumentList, never a shell.
    if ($probeProviderName -notmatch '^[A-Za-z0-9._-]{1,64}$') { return $null }
    try {
        $binary = Resolve-CodexBarBinaryPath -ProbeCommand $ProbeCommand
        if ($null -eq $Runner -and [string]::IsNullOrWhiteSpace($binary)) { return $null }
        $exeArgs = [string[]]@('usage', '--provider', $probeProviderName, '--json')
        $run = if ($null -ne $Runner) { & $Runner $binary $exeArgs $TimeoutSeconds }
               else { Invoke-CodexBarUsageProcess -FilePath $binary -ArgumentList $exeArgs -TimeoutSeconds $TimeoutSeconds }
        if ($null -eq $run) { return $null }

        $exitCode = 0
        if (-not [int]::TryParse([string](Get-ProbeObjectField -InputObject $run -Field 'exit_code'), [ref]$exitCode)) { return $null }
        if ($exitCode -ne 0) { return $null }
        $stdout = [string](Get-ProbeObjectField -InputObject $run -Field 'stdout')
        if ([string]::IsNullOrWhiteSpace($stdout)) { return $null }
        $payload = $null
        try { $payload = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
        if ($null -eq $payload) { return $null }
        $entries = @($payload)
        if ($entries.Count -eq 0) { return $null }

        $durationMs = 0
        [void][int]::TryParse([string](Get-ProbeObjectField -InputObject $run -Field 'duration_ms'), [ref]$durationMs)
        return [ordered]@{
            transport = 'codexbar-cli'
            provider = $probeProviderName
            exit_code = $exitCode
            duration_ms = $durationMs
            entries = $entries
        }
    } catch {
        return $null
    }
}

function ConvertTo-CodexBarObservation {
    <# One codexbar window object -> one observation row in Baton's existing shape.
       Unknown durations and malformed values are dropped (return $null), never
       coerced. $ScopeId is $null for a plan-wide window and the window's own id
       for a model-scoped sub-quota. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        $Window,
        [Parameter(Mandatory)][string]$SourceLabel,
        [Parameter(Mandatory)][datetimeoffset]$ObservedAt,
        [Parameter(Mandatory)][int]$TtlSeconds,
        [string]$ScopeId
    )
    if ($null -eq $Window) { return $null }
    $minutes = 0
    if (-not [int]::TryParse([string](Get-ProbeObjectField -InputObject $Window -Field 'window_minutes'), [ref]$minutes)) { return $null }
    $scope = if ($minutes -eq 300) { 'five_hour' } elseif ($minutes -eq 10080) { 'weekly' } else { $null }
    if (-not $scope) { return $null }

    $used = [double]0
    if (-not [double]::TryParse(
            [string](Get-ProbeObjectField -InputObject $Window -Field 'used_percent'),
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$used) -or
        -not [double]::IsFinite($used) -or $used -lt 0 -or $used -gt 100) { return $null }

    # ISO-8601 here, NOT an epoch like the codex-rate-limit transport. Normalize to
    # a round-trip UTC string so every observation compares the same way downstream.
    # ConvertFrom-Json turns an ISO timestamp into a real [datetime], so the typed
    # value must be taken as-is; re-stringifying it would run it through the current
    # culture and silently shift the instant.
    $resetValue = Get-ProbeObjectField -InputObject $Window -Field 'resets_at'
    $resetInstant = [datetimeoffset]::MinValue
    if ($resetValue -is [datetimeoffset]) {
        $resetInstant = [datetimeoffset]$resetValue
    } elseif ($resetValue -is [datetime]) {
        $resetDate = [datetime]$resetValue
        if ($resetDate.Kind -eq [System.DateTimeKind]::Unspecified) {
            $resetDate = [datetime]::SpecifyKind($resetDate, [System.DateTimeKind]::Utc)
        }
        $resetInstant = [datetimeoffset]$resetDate
    } else {
        $resetText = [string]$resetValue
        if ([string]::IsNullOrWhiteSpace($resetText)) { return $null }
        if (-not [datetimeoffset]::TryParse(
                $resetText,
                [System.Globalization.CultureInfo]::InvariantCulture,
                ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal),
                [ref]$resetInstant)) { return $null }
    }

    $row = [ordered]@{
        worker = $Worker
        scope = $scope
        scope_id = if ([string]::IsNullOrWhiteSpace($ScopeId)) { $null } else { $ScopeId.Trim() }
        used_pct = $used
        reset_at = $resetInstant.ToUniversalTime().ToString('o')
        source = $SourceLabel
        observed_at = $ObservedAt.ToString('o')
        ttl = $TtlSeconds
        confidence = [double]0.9
    }
    return $row
}

function ConvertFrom-CodexBarUsageResponse {
    <# Normalize a codexbar usage payload to the observation contract.

       extra_rate_windows are REAL model-scoped quotas, not decoration: each one is
       emitted as its own observation carrying its window id in scope_id, with the
       same scope shape as the plan-wide windows so the existing cap knobs apply.
       A plan-wide window sat at a comfortable number while a model-scoped window
       was fully exhausted is a live, observed case — reading only primary/secondary
       would route work to a model with nothing left. An absent or empty
       extra_rate_windows is normal, not an error. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        $Response,
        [datetimeoffset]$ObservedAt = [datetimeoffset]::UtcNow,
        [int]$TtlSeconds = 600
    )
    if ($TtlSeconds -le 0 -or $null -eq $Response -or $Response -is [string]) { return $null }
    $entries = Get-ProbeObjectField -InputObject $Response -Field 'entries'
    if ($null -eq $entries) { $entries = $Response }
    $entryList = @($entries | Where-Object { $null -ne $_ })
    if ($entryList.Count -eq 0) { return $null }

    $rows = [System.Collections.ArrayList]@()
    foreach ($entry in $entryList) {
        if ($entry -is [string]) { continue }
        # `source` records HOW the figure was obtained (oauth, a browser session, ...).
        # Keep it prefixed so provenance survives into the journal and the cache.
        $entrySource = [string](Get-ProbeObjectField -InputObject $entry -Field 'source')
        if ([string]::IsNullOrWhiteSpace($entrySource)) { $entrySource = 'unknown' }
        $sourceLabel = "codexbar:$($entrySource.Trim())"

        $usage = Get-ProbeObjectField -InputObject $entry -Field 'usage'
        foreach ($windowName in @('primary', 'secondary')) {
            $observation = ConvertTo-CodexBarObservation -Worker $Worker `
                -Window (Get-ProbeObjectField -InputObject $usage -Field $windowName) `
                -SourceLabel $sourceLabel -ObservedAt $ObservedAt -TtlSeconds $TtlSeconds
            if ($null -ne $observation) { [void]$rows.Add($observation) }
        }

        $extraWindows = Get-ProbeObjectField -InputObject $entry -Field 'extra_rate_windows'
        if ($null -eq $extraWindows) { continue }
        foreach ($extra in @($extraWindows | Where-Object { $null -ne $_ })) {
            # An id-less scoped window cannot be bound to a row, and emitting it
            # without one would make it read as plan-wide. Drop it instead.
            $scopeId = [string](Get-ProbeObjectField -InputObject $extra -Field 'id')
            if ([string]::IsNullOrWhiteSpace($scopeId)) { continue }
            $observation = ConvertTo-CodexBarObservation -Worker $Worker `
                -Window (Get-ProbeObjectField -InputObject $extra -Field 'window') `
                -SourceLabel $sourceLabel -ObservedAt $ObservedAt -TtlSeconds $TtlSeconds -ScopeId $scopeId
            if ($null -ne $observation) { [void]$rows.Add($observation) }
        }
    }
    if ($rows.Count -eq 0) { return $null }
    return ,([object[]]$rows.ToArray())
}

function Invoke-OpenRouterKeyTransport {
    <# GET {base_url}/v1/key for the account behind a row's api_key_env.

       Identity fails CLOSED: with no api_key_env, or an unset variable, this
       returns $null WITHOUT a network call. There is no anonymous form of this
       question — an unauthenticated /v1/key describes no account at all, so
       guessing would be worse than not asking. Everything else fails soft.
       -Invoker is the hermetic test seam; production uses Invoke-RestMethod. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [int]$TimeoutSeconds = 20,
        [scriptblock]$Invoker
    )
    if ($TimeoutSeconds -le 0) { return $null }
    try {
        if ([string]::IsNullOrWhiteSpace([string]$Provider.api_key_env)) { return $null }
        if ([string]::IsNullOrWhiteSpace([string]$Provider.base_url)) { return $null }
        $auth = Resolve-FleetHttpAuth -Provider $Provider
        if ($auth.error -or $null -eq $auth.headers) { return $null }
        $uri = "$([string]$Provider.base_url.TrimEnd('/'))/v1/key"
        if ($Invoker) { return (& $Invoker $uri $auth.headers $TimeoutSeconds) }
        return Invoke-RestMethod -Uri $uri -Method Get -Headers $auth.headers -TimeoutSec $TimeoutSeconds
    } catch {
        # Probes observe; they never change dispatch by throwing.
        return $null
    }
}

function ConvertFrom-OpenRouterKeyResponse {
    <# Normalize a /v1/key response to one `paid_credit` observation.

       Prepaid credit is a DEPLETING BALANCE, not a rolling window, which drives
       two deliberate choices:

       - `limit: null` (an uncapped key) returns $null. There is no percentage of
         infinity. Reporting 0% would read as "plenty of headroom" and is the
         one wrong answer here; "no observation" is the honest one, and leaves
         the vendor-side ceiling as the only guard — which is what it is.
       - No reset_at is invented. OpenRouter only resets when limit_reset says
         so; a fabricated timestamp would make a draining balance look like it
         refills, and downstream advisories key off exactly that field. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [Parameter(Mandatory)]$Response,
        [datetimeoffset]$ObservedAt = [datetimeoffset]::UtcNow,
        [int]$TtlSeconds = 600
    )
    if ($TtlSeconds -le 0 -or $null -eq $Response -or $Response -is [string]) { return $null }
    $data = Get-ProbeObjectField -InputObject $Response -Field 'data'
    if ($null -eq $data) { return $null }

    $limitRaw = Get-ProbeObjectField -InputObject $data -Field 'limit'
    $usageRaw = Get-ProbeObjectField -InputObject $data -Field 'usage'
    if ($null -eq $limitRaw -or $null -eq $usageRaw) { return $null }

    $limit = [double]0
    $usage = [double]0
    if (-not [double]::TryParse([string]$limitRaw, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$limit)) { return $null }
    if (-not [double]::TryParse([string]$usageRaw, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$usage)) { return $null }
    if (-not [double]::IsFinite($limit) -or -not [double]::IsFinite($usage)) { return $null }
    if ($limit -le 0 -or $usage -lt 0) { return $null }

    # Spend past the limit is possible in flight; clamp so the cap comparison
    # stays on the 0-100 scale the other windows use.
    $usedPct = [math]::Min([double]100, ($usage / $limit) * 100)

    $observation = [ordered]@{
        worker = $Worker
        scope = 'paid_credit'
        used_pct = $usedPct
        consumed = $usage
        allowance = $limit
        source = 'openrouter_key_probe'
        observed_at = $ObservedAt.ToString('o')
        ttl = $TtlSeconds
        confidence = [double]0.95
    }
    # Only a vendor-declared cycle earns a reset; a prepaid balance gets none.
    $limitReset = [string](Get-ProbeObjectField -InputObject $data -Field 'limit_reset')
    if (-not [string]::IsNullOrWhiteSpace($limitReset)) { $observation.limit_reset = $limitReset.Trim() }
    return ,([object[]]@($observation))
}

# ---------------------------------------------------------------------------
# Usage-probe transport registry (#173)
#
# One entry per observable provider surface, keyed by transport NAME. Each entry
# pairs the fetch half with the parse half so a caller never has to know which
# platform it is talking to:
#   invoke <clientVersion> <timeoutSeconds> <providerRow>  -> raw response (or $null)
#   parse  <worker> <response> <observedAt> <ttlSecs>      -> observation rows (or $null)
# An entry may also declare `requires_policy`: usage_policy fields that MUST be
# present before the transport is allowed to resolve. That is the fail-closed
# identity gate — a transport that cannot tell which account it would query does
# not run at all, rather than guessing.
# Adding a provider means registering a pair here; nothing downstream changes.
# ---------------------------------------------------------------------------
$script:UsageProbeTransports = [ordered]@{
    'codex-rate-limit' = [ordered]@{
        name = 'codex-rate-limit'
        requires_policy = [string[]]@()
        invoke = {
            param($clientVersion, $timeoutSeconds, $providerRow)
            Invoke-CodexRateLimitTransport -ClientVersion $clientVersion -TimeoutSeconds $timeoutSeconds
        }
        parse = {
            param($worker, $response, $observedAt, $ttlSeconds)
            ConvertFrom-CodexRateLimitResponse -Worker $worker -Response $response `
                -ObservedAt $observedAt -TtlSeconds $ttlSeconds
        }
    }
    'codexbar-cli' = [ordered]@{
        name = 'codexbar-cli'
        # Identity is fail-closed: no probe_provider, no probe.
        requires_policy = [string[]]@('probe_provider')
        invoke = {
            param($clientVersion, $timeoutSeconds, $providerRow)
            $rowPolicy = if ($null -ne $providerRow) { $providerRow.usage_policy } else { $null }
            Invoke-CodexBarUsageTransport `
                -ProbeProvider ([string](Get-UsagePolicyField -Policy $rowPolicy -Field 'probe_provider')) `
                -TimeoutSeconds $timeoutSeconds `
                -ProbeCommand ([string](Get-UsagePolicyField -Policy $rowPolicy -Field 'probe_command'))
        }
        parse = {
            param($worker, $response, $observedAt, $ttlSeconds)
            ConvertFrom-CodexBarUsageResponse -Worker $worker -Response $response `
                -ObservedAt $observedAt -TtlSeconds $ttlSeconds
        }
    }
    'openrouter-key' = [ordered]@{
        name = 'openrouter-key'
        # Identity rides on the ROW's api_key_env rather than a usage_policy
        # field — the key IS the account — so requires_policy stays empty and
        # the invoke enforces the same fail-closed rule itself.
        requires_policy = [string[]]@()
        invoke = {
            param($clientVersion, $timeoutSeconds, $providerRow)
            if ($null -eq $providerRow) { return $null }
            Invoke-OpenRouterKeyTransport -Provider ([hashtable]$providerRow) -TimeoutSeconds $timeoutSeconds
        }
        parse = {
            param($worker, $response, $observedAt, $ttlSeconds)
            ConvertFrom-OpenRouterKeyResponse -Worker $worker -Response $response `
                -ObservedAt $observedAt -TtlSeconds $ttlSeconds
        }
    }
}

function Get-UsageProbeTransport {
    <# Look one transport up by name. An unknown or blank name returns $null —
       callers must treat that as "do not probe", never as "try something". #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($null -eq $script:UsageProbeTransports) { return $null }
    $key = $Name.Trim()
    if (-not $script:UsageProbeTransports.Contains($key)) { return $null }
    return $script:UsageProbeTransports[$key]
}

function Get-UsageProbeTransportName {
    <# Registered transport names, for doctor output and tests. #>
    if ($null -eq $script:UsageProbeTransports) { return ,[string[]]@() }
    return ,[string[]]@($script:UsageProbeTransports.Keys)
}

function Get-UsagePolicyField {
    <# usage_policy is a hashtable off Read-Fleet but a PSCustomObject when it
       comes back through JSON; read either without throwing. #>
    param($Policy, [Parameter(Mandatory)][string]$Field)
    return (Get-ProbeObjectField -InputObject $Policy -Field $Field)
}

function Test-UsageProbeTransportRequirement {
    <# Does this row carry every usage_policy field the transport needs to know
       WHO it is querying? Missing identity => the transport must not resolve. #>
    param($TransportPair, $Policy)
    if ($null -eq $TransportPair) { return $false }
    $required = @(Get-ProbeObjectField -InputObject $TransportPair -Field 'requires_policy')
    foreach ($field in $required) {
        if ([string]::IsNullOrWhiteSpace([string]$field)) { continue }
        $value = Get-UsagePolicyField -Policy $Policy -Field ([string]$field)
        if ([string]::IsNullOrWhiteSpace([string]$value)) { return $false }
    }
    return $true
}

function Resolve-UsageProbeTransportName {
    <# Decide WHICH transport a provider row gets, by name. Precedence:
         1. explicit usage_policy.probe_transport, else
         2. the back-compat inference below, else
         3. nothing.
       Returns a REGISTERED name or $null. An unrecognized name resolves to
       $null rather than throwing, so a typo or a not-yet-shipped transport
       means "no probe" — never a speculative attempt against the wrong API. #>
    param($Provider)
    if ($null -eq $Provider) { return $null }
    $policy = $Provider.usage_policy
    if ($null -eq $policy) { return $null }

    $declared = [string](Get-UsagePolicyField -Policy $policy -Field 'probe_transport')
    if (-not [string]::IsNullOrWhiteSpace($declared)) {
        $declaredPair = Get-UsageProbeTransport -Name $declared
        if ($null -eq $declaredPair) { return $null }
        # Fail closed on identity: a transport whose required usage_policy fields
        # are missing resolves to nothing rather than querying an unknown account.
        if (-not (Test-UsageProbeTransportRequirement -TransportPair $declaredPair -Policy $policy)) { return $null }
        return $declared.Trim()
    }

    # BACK-COMPAT INFERENCE (temporary). The operator's live fleet.yaml predates
    # probe_transport, so a cli/codex row with no declared transport keeps the
    # adapter it has always used. This exists ONLY so that config keeps working
    # untouched; drop this branch once every probing row declares its transport.
    if (([string]$Provider.kind -eq 'cli') -and ([string]$Provider.platform -eq 'codex')) {
        return 'codex-rate-limit'
    }
    # An OpenRouter row carries its own identity (api_key_env), so the transport
    # is unambiguous from the platform alone — no config field to forget.
    if (([string]$Provider.kind -eq 'http') -and ([string]$Provider.platform -eq 'openrouter')) {
        return 'openrouter-key'
    }
    return $null
}

function Test-UsageProbeEligible {
    <# The single probe-eligibility predicate: the policy opts in AND a transport
       resolves. Everything else (cache TTL, timeouts, cap decision) is unchanged
       and downstream. No transport never blocks dispatch — it only skips the probe. #>
    param($Provider)
    if ($null -eq $Provider) { return $false }
    $policy = $Provider.usage_policy
    if ($null -eq $policy) { return $false }
    if ((Get-UsagePolicyField -Policy $policy -Field 'probe') -ne $true) { return $false }
    return ($null -ne (Resolve-UsageProbeTransportName -Provider $Provider))
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

function Get-ProviderUsageProbe {
    <# Provider-generic probe entry (#173). Resolve the transport by name — from
       -TransportName, else from the -Provider row — then run the registered
       invoke+parse pair. Returns the same snapshot shape for every transport, so
       the cache and cap-decision code downstream is untouched.

       No resolvable transport => $null and NOTHING attempted (fail closed).
       The optional -Transport seam overrides only the fetch half; its contract is
       unchanged: (& transport <clientVersion> <timeoutSeconds>) -> raw response.
       -Force skips a still-TTL'd cache row (window-boundary refresh must not keep
       pre-reset five_hour remaining). #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        $Provider,
        [string]$TransportName,
        [scriptblock]$Transport,
        [string]$CachePath = (Join-Path (Get-BatonHome) 'usage-probe-cache.jsonl'),
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
        [int]$TimeoutSeconds = 20,
        [int]$TtlSeconds = 600,
        [switch]$Force
    )
    if ($TimeoutSeconds -le 0 -or $TtlSeconds -le 0) { return $null }
    $resolvedName = if (-not [string]::IsNullOrWhiteSpace($TransportName)) { $TransportName }
                    else { Resolve-UsageProbeTransportName -Provider $Provider }
    $transportPair = Get-UsageProbeTransport -Name $resolvedName
    if ($null -eq $transportPair) { return $null }

    if (-not $Force) {
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
    }

    try {
        $version = Get-BatonPluginVersion
        # The provider row rides along as a third argument so a transport can read
        # its own usage_policy (which account to query, which binary to run).
        # Two-parameter transports simply ignore it.
        $response = if ($Transport) { & $Transport $version $TimeoutSeconds $Provider }
                    else { & $transportPair.invoke $version $TimeoutSeconds $Provider }
        $observations = & $transportPair.parse $Worker $response $Now $TtlSeconds
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

function Get-CodexUsageProbe {
    <# Named entry for the codex-rate-limit transport, kept for existing callers
       (heartbeat window refresh, tests). Thin wrapper over Get-ProviderUsageProbe. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [scriptblock]$Transport,
        [string]$CachePath = (Join-Path (Get-BatonHome) 'usage-probe-cache.jsonl'),
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
        [int]$TimeoutSeconds = 20,
        [int]$TtlSeconds = 600,
        [switch]$Force
    )
    $probeParams = @{
        Worker = $Worker
        TransportName = 'codex-rate-limit'
        CachePath = $CachePath
        Now = $Now
        TimeoutSeconds = $TimeoutSeconds
        TtlSeconds = $TtlSeconds
    }
    if ($Transport) { $probeParams.Transport = $Transport }
    if ($Force) { $probeParams.Force = $true }
    return Get-ProviderUsageProbe @probeParams
}

function Get-UsageProbeCapDecision {
    <# Cap decision over a set of observations.

       SCOPE BINDING (#173). Some providers report per-model sub-quotas alongside
       the plan-wide windows; those arrive as observations carrying a scope_id.
       - A row with no usage_policy.scope_id is judged on the plan-wide windows
         ONLY — another model's exhausted sub-quota is not its problem.
       - A row bound to a scope_id is judged on the plan-wide windows AND the
         matching scoped window, so an exhausted sub-quota holds the row even when
         the plan-wide window still has room.
       - A row bound to a scope_id that is ABSENT from the response falls back to
         the plan-wide windows. This is deliberate and load-bearing: the set of
         windows is plan-dependent and changes when the account's tier changes.
         Losing a scoped window means losing INFORMATION, never gaining headroom —
         treating the absence as "unlimited" would silently uncap the row at the
         exact moment the plan was downgraded. Nothing here keys off a known id. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][object[]]$Observations
    )
    $checked = [System.Collections.ArrayList]@()
    $crossings = [System.Collections.ArrayList]@()
    $policy = $Provider.usage_policy
    if ($null -eq $policy) { return [ordered]@{ over_cap = $false; checked = @(); windows = @() } }
    $boundScopeId = [string](Get-UsagePolicyField -Policy $policy -Field 'scope_id')
    foreach ($observation in @($Observations)) {
        $observationScopeId = [string](Get-ProbeObjectField -InputObject $observation -Field 'scope_id')
        if (-not [string]::IsNullOrWhiteSpace($observationScopeId)) {
            # A scoped window counts only for the row bound to exactly that scope.
            if ([string]::IsNullOrWhiteSpace($boundScopeId)) { continue }
            if ($observationScopeId.Trim() -ne $boundScopeId.Trim()) { continue }
        }
        $knob = if ([string]$observation.scope -eq 'five_hour') { 'soft_cap_5h' }
                elseif ([string]$observation.scope -eq 'weekly') { 'soft_cap_weekly' }
                elseif ([string]$observation.scope -eq 'paid_credit') { 'soft_cap_credit' }
                else { $null }
        if (-not $knob -or $null -eq $policy[$knob]) { continue }
        $used = [double]$observation.used_pct
        $cap = [double]$policy[$knob]
        $windowDecision = [ordered]@{
            window = [string]$observation.scope
            scope_id = if ([string]::IsNullOrWhiteSpace($observationScopeId)) { $null } else { $observationScopeId.Trim() }
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
        # Provenance comes from the observation that crossed, so a codexbar-sourced
        # row is never journaled as if the app-server had reported it.
        $windowSource = [string]$window.source
        if ([string]::IsNullOrWhiteSpace($windowSource)) { $windowSource = 'app_server_probe' }
        $row = [ordered]@{
            ts = [string]$window.observed_at
            event = 'limited'
            worker = $Worker
            scope = [string]$window.window
            scope_id = [string]$window.scope_id
            window = [string]$window.window
            used_pct = [double]$window.used_pct
            cap = [double]$window.cap
            policy_knob = [string]$window.policy_knob
            reset_at = [string]$window.reset_at
            source = $windowSource
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
        # Provenance follows the window that actually crossed, matching
        # Add-UsageProbeLimitedRows. Hardcoding app_server_probe here would file
        # every non-codex transport's preflight under codex's name, which makes
        # the journal quietly wrong rather than loudly broken.
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
        # The crossing window knows which transport observed it; prefer that over
        # the codex-era default so a second transport is never misattributed.
        $primarySource = [string]$primary.source
        if (-not [string]::IsNullOrWhiteSpace($primarySource)) { $row.source = $primarySource }
        $row.reset_at = [string]$primary.reset_at
        if (-not [string]::IsNullOrWhiteSpace([string]$primary.scope_id)) { $row.scope_id = [string]$primary.scope_id }
        if (-not [string]::IsNullOrWhiteSpace([string]$primary.source)) { $row.source = [string]$primary.source }
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
        # Name the sub-quota when one crossed, so a scoped hold is never read as a
        # plan-wide one (the two can appear together with the same window shape).
        $scopeText = if ([string]::IsNullOrWhiteSpace([string]$wd.scope_id)) { '' } else { " scope $($wd.scope_id)" }
        "at $used% of $($wd.window)$scopeText (resets $($wd.reset_at)), reached $($wd.policy_knob)=$cap"
    }
    $evidence = ($evidenceParts -join '; ')
    $line = "usage preflight: $Worker is $evidence"
    if ($Outcome -eq 'rerouted') { return "$line; rerouting to $Substitute" }
    if ($AlsoOverCap) {
        return "$line; $AlsoOverCap also over soft cap; held (no further hop)"
    }
    return "$line; no peer available + $Worker over soft cap"
}
