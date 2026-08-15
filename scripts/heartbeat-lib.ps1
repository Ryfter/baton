#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Usage-window heartbeat: fire one minimal call at the 5-hour reset boundary so the
  next window starts at a clock time the operator chose, and fold the free
  housekeeping (stale lockouts, session liveness) into the same tick.
.DESCRIPTION
  Three jobs, one scheduled event — only the first spends anything:

    1. ANCHOR (costs tokens). The 5h window starts at its FIRST request, so a window
       nobody touches at reset drifts to whenever work happens to begin. One tiny
       request at reset+epsilon pins the next boundary to a predictable time.
       MUST use subscription auth: `claude --bare` is cheaper but its docs state auth
       becomes strictly ANTHROPIC_API_KEY (OAuth/keychain never read), which bills the
       API and touches no subscription window at all — cheap and useless here.
    2. CLEAR (free). Workers whose reset_at has passed get an explicit `clear` row, so
       the labor pool stops reporting a lockout that expired (#124 honesty).
    3. LIVENESS (free). Stamp a heartbeat marker so the dashboard can tell a live
       session from a marker that merely has not aged out yet.

  Boundaries are computed from a FIXED anchor (anchor + N*5h), not from the last fire
  time, so a late or skipped beat cannot make the schedule creep.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/usage-lib.ps1"
. "$PSScriptRoot/session-markers-lib.ps1"   # Get-ActiveSessions for the liveness half
. "$PSScriptRoot/usage-probe-lib.ps1"       # Get-CodexUsageProbe for free probe refresh

$script:HeartbeatWindowHours = 5
# Machine-scoped journals live once under BATON_HOME (not per project); rotate before they bloat.
$script:JournalRotateMaxBytes = 512KB

function Get-HeartbeatStatePath {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'heartbeat.json')
}

function Read-HeartbeatState {
    <# Persisted anchor + last-fire record. Missing/corrupt -> empty state (fail-soft:
       a broken state file must never wedge the schedule). #>
    param([string]$Path = (Get-HeartbeatStatePath))
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{ anchor = $null; anchor_from_beat = $false; last_fired_at = $null; beats = 0; last_beat_started_window = $false }
    }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [ordered]@{
            anchor                    = [string]$doc.anchor
            anchor_from_beat          = [bool]($doc.anchor_from_beat ?? $false)
            last_fired_at             = [string]$doc.last_fired_at
            beats                     = [int]($doc.beats ?? 0)
            last_beat_started_window  = [bool]($doc.last_beat_started_window ?? $false)
        }
    } catch {
        return [ordered]@{ anchor = $null; anchor_from_beat = $false; last_fired_at = $null; beats = 0; last_beat_started_window = $false }
    }
}

function Write-HeartbeatState {
    param(
        [Parameter(Mandatory)]$State,
        [string]$Path = (Get-HeartbeatStatePath)
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ConvertTo-Json -InputObject $State -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
    return $Path
}

function Resolve-HeartbeatAnchor {
    <# Accept an operator anchor as a clock time ('3:50', '03:50', '15:50') or a full
       timestamp. A bare clock time means TODAY's occurrence, kept as-is whether that is
       past or still ahead: the grid math handles both, and rolling a bare time back a
       day would move the phase by 4h (24 mod 5), silently putting every boundary on the
       wrong schedule. Unparseable -> $null (caller reports it; never guess a boundary). #>
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [datetimeoffset]$Now = [datetimeoffset]::Now
    )
    $text = $Anchor.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    # A bare clock time carries no date, and [datetimeoffset]::TryParse fills the missing
    # one from the SYSTEM clock -- which ignored -Now entirely and returned the right hour
    # on the wrong day. Build it from $Now instead, so "TODAY's occurrence" means today
    # relative to the caller's clock. Anything not a bare HH:mm[:ss] still passes through
    # TryParse, which is correct for a full timestamp (it carries its own date and offset).
    if ($text -match '^([01]?\d|2[0-3]):([0-5]\d)(:([0-5]\d))?$') {
        $anchorHour = [int]$Matches[1]
        $anchorMinute = [int]$Matches[2]
        $anchorSecond = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        return [datetimeoffset]::new($Now.Year, $Now.Month, $Now.Day,
            $anchorHour, $anchorMinute, $anchorSecond, $Now.Offset)
    }
    $full = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($text, [ref]$full)) { return $full }
    return $null
}

function Test-HeartbeatOpensWindow {
    <# Did THIS beat start a new window? True when it is the first beat since the most
       recent boundary. Stated that way rather than "fired within N minutes of a
       boundary" so the normal Windows failure — the machine asleep at the boundary,
       task runs late — still re-anchors: that late request genuinely is the window's
       first, and pretending otherwise would desync the schedule from reality forever.
       No prior anchor -> true (the first beat necessarily opens one). #>
    param($PriorAnchor, $LastFiredAt, [datetimeoffset]$Now = [datetimeoffset]::Now)
    if (-not $PriorAnchor) { return $true }
    $windowSeconds = $script:HeartbeatWindowHours * 3600
    $elapsed = ($Now - $PriorAnchor).TotalSeconds
    if ($elapsed -lt 0) { return $false }          # anchor still ahead: no window open yet
    if ($elapsed -lt $windowSeconds) {
        # Still inside the anchor's own window — only the beat that opened it counts,
        # and that one already happened (it set the anchor).
        return $false
    }
    $mostRecentBoundary = $PriorAnchor.AddSeconds([math]::Floor($elapsed / $windowSeconds) * $windowSeconds)
    if (-not $LastFiredAt) { return $true }
    return ($LastFiredAt -lt $mostRecentBoundary)
}

function Get-HeartbeatEpsilon {
    <# The offset to add to a boundary. An operator-supplied anchor is the time the window
       RESETS, so it needs the "+1 min" offset. An anchor set by a beat is already a window
       START (the fire time, offset included), so adding epsilon again would push every
       later boundary a minute later — a 1-min-per-beat creep. #>
    param($State, [int]$Requested = 60)
    if ($State -and [bool]$State.anchor_from_beat) { return 0 }
    return $Requested
}

function Get-NextHeartbeatBoundary {
    <# The next window boundary at/after -Now, as anchor + N*5h. Fixed-anchor arithmetic
       (not last-fire + 5h) so a missed beat never shifts the cadence. -EpsilonSeconds is
       the operator's "reset at 3:50 -> beat at 3:51" offset. #>
    param(
        [Parameter(Mandatory)][datetimeoffset]$Anchor,
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [int]$EpsilonSeconds = 60
    )
    $windowSeconds = $script:HeartbeatWindowHours * 3600
    $elapsed = ($Now - $Anchor).TotalSeconds
    $n = [math]::Floor($elapsed / $windowSeconds)
    if ($n -lt 0) { $n = 0 }
    $boundary = $Anchor.AddSeconds(($n * $windowSeconds) + $EpsilonSeconds)
    while ($boundary -le $Now) {
        $n++
        $boundary = $Anchor.AddSeconds(($n * $windowSeconds) + $EpsilonSeconds)
    }
    return [ordered]@{
        boundary_at    = $boundary
        window_index   = [int]$n
        seconds_until  = [int][math]::Max(0, ($boundary - $Now).TotalSeconds)
    }
}

function Get-AnchorHeartbeatArgv {
    <# The argv for the cheapest SUBSCRIPTION-authenticated request measured on this box
       (2026-07-26: ~26k input / ~60 output on haiku). The bulk is Claude Code's built-in
       system prompt and tool schemas, which no flag fully removes on this auth path —
       the user prompt is rounding error, so it is kept trivial rather than clever.
       Deliberately NOT --bare: that flag forces API-key auth and would anchor nothing.
       Asking for the time is avoided on purpose: the model has no clock and burns output
       explaining that. #>
    param([string]$Model = 'haiku')
    return @(
        '-p', 'ok'
        '--model', $Model
        '--system-prompt', 'Reply with exactly: ok'
        '--strict-mcp-config'
        '--no-session-persistence'
        '--output-format', 'json'
    )
}

function Invoke-AnchorHeartbeat {
    <# Fire the anchoring request from a neutral cwd (no CLAUDE.md discovery) and report
       measured usage. -Transport injects a fake for hermetic tests. Never throws: a
       failed anchor must still let the free housekeeping run and the next beat schedule. #>
    param(
        [string]$Model = 'haiku',
        [scriptblock]$Transport,
        [int]$TimeoutSeconds = 120
    )
    $argv = Get-AnchorHeartbeatArgv -Model $Model
    if ($Transport) {
        try {
            $raw = [string](& $Transport $argv)
        } catch {
            return [ordered]@{ ok = $false; reason = $_.Exception.Message; input_tokens = $null; output_tokens = $null; cost_usd = $null; spend_known = $false }
        }
    } else {
        $neutral = Join-Path ([System.IO.Path]::GetTempPath()) 'baton-heartbeat'
        if (-not (Test-Path -LiteralPath $neutral)) { New-Item -ItemType Directory -Force -Path $neutral | Out-Null }
        $prev = Get-Location
        try {
            Set-Location -LiteralPath $neutral
            $raw = [string](& claude @argv 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) {
                # Tokens stay UNKNOWN, not zero: a nonzero exit does not prove nothing was
                # billed, and reporting 0 would understate real spend.
                return [ordered]@{ ok = $false; reason = "claude exit $LASTEXITCODE"; input_tokens = $null; output_tokens = $null; cost_usd = $null; spend_known = $false }
            }
        } catch {
            return [ordered]@{ ok = $false; reason = $_.Exception.Message; input_tokens = $null; output_tokens = $null; cost_usd = $null; spend_known = $false }
        } finally {
            Set-Location $prev
        }
    }
    try {
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
        $u = $doc.usage
        $inTotal = [long](($u.input_tokens ?? 0) + ($u.cache_read_input_tokens ?? 0) + ($u.cache_creation_input_tokens ?? 0))
        return [ordered]@{
            ok            = $true
            reason        = ''
            input_tokens  = $inTotal
            output_tokens = [long]($u.output_tokens ?? 0)
            cost_usd      = $doc.total_cost_usd
            spend_known   = $true
            result        = [string]$doc.result
        }
    } catch {
        # Unknown, not zero: the request may well have billed before the response
        # became unreadable, and reporting 0 would understate real spend.
        return [ordered]@{ ok = $false; reason = 'unparseable claude response (spend unknown — the request may still have billed)'; input_tokens = $null; output_tokens = $null; cost_usd = $null; spend_known = $false }
    }
}

function Clear-ExpiredWorkerLockouts {
    <# Free half of the beat: every worker whose reset_at has already passed gets an
       explicit `clear` row. Get-WorkerState time-expires these implicitly, but an
       explicit row makes the journal say so — an operator reading it should not have to
       re-derive that a lockout is over (#124). Returns the workers cleared. #>
    param(
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl'),
        [datetime]$Now = [datetime]::UtcNow
    )
    $cleared = [System.Collections.ArrayList]@()
    try {
        $rows = @(Read-UsageJournal -Path $UsagePath)
        if ($rows.Count -eq 0) { return @() }
        $workers = @($rows | ForEach-Object { [string]$_.worker } | Where-Object { $_ -and $_ -ne '*' } | Select-Object -Unique)
        foreach ($w in $workers) {
            $st = Get-WorkerState -Worker $w -Rows $rows -Now $Now
            # Already available (time-expired or explicitly cleared) AND the journal's
            # latest row still says otherwise -> write the clear so the record is honest.
            if ([string]$st.state -ne 'available') { continue }
            $latest = @($rows | Where-Object { [string]$_.worker -eq $w -and $_.event -in @('lockout','limited','cooldown','clear') }) |
                Sort-Object { ConvertTo-UsageDateTime ([string]$_.ts) } | Select-Object -Last 1
            if ($null -eq $latest -or [string]$latest.event -eq 'clear') { continue }
            Clear-Worker -Worker $w -UsagePath $UsagePath
            [void]$cleared.Add($w)
        }
    } catch { Write-Debug "Clear-ExpiredWorkerLockouts: $($_.Exception.Message)" }
    return @($cleared.ToArray())
}

function Write-HeartbeatLiveness {
    <# Free half of the beat: a dated liveness stamp the dashboard can read to tell a
       live session from a marker that merely has not hit its TTL yet. Cheap, local,
       and safe to call when nothing else in the beat succeeded.
       Reports what the session markers actually say — and marker stamping is itself
       broken for most session kinds right now (#144), so a live box legitimately reads
       0 until that is fixed. Reporting the real count beats inventing a plausible one. #>
    param(
        [string]$BatonHome = (Get-BatonHome),
        [datetimeoffset]$Now = [datetimeoffset]::Now
    )
    $dir = Join-Path $BatonHome 'sessions'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-Path $dir 'heartbeat.json'
    $live = @()
    try { $live = @(Get-ActiveSessions -BatonHome $BatonHome) } catch { }
    $rec = [ordered]@{
        kind            = 'heartbeat'
        at              = $Now.ToString('o')
        live_sessions   = $live.Count
        session_cwds    = @($live | ForEach-Object { [string]$_.cwd } | Where-Object { $_ })
    }
    ConvertTo-Json -InputObject $rec -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $rec
}

function Invoke-HeartbeatUsageProbeRefresh {
    <# Free half of the beat: force-refresh the codex usage-probe cache so the new
       window's routing decisions see post-reset remaining, not a still-TTL'd snapshot
       from the prior window. Never throws. #>
    param(
        [string]$BatonHome = (Get-BatonHome),
        [scriptblock]$ProbeTransport,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
        [string]$Worker = 'codex'
    )
    $cachePath = Join-Path $BatonHome 'usage-probe-cache.jsonl'
    try {
        $snapshot = Get-CodexUsageProbe -Worker $Worker -Transport $ProbeTransport `
            -CachePath $cachePath -Now $Now -TimeoutSeconds 20 -TtlSeconds 600 -Force
        if ($null -eq $snapshot) {
            return [ordered]@{ ok = $false; reason = 'probe returned null'; worker = $Worker; cached = $false; observation_count = 0 }
        }
        return [ordered]@{
            ok                 = $true
            reason             = ''
            worker             = $Worker
            cached             = [bool]$snapshot.cached
            observation_count  = @($snapshot.observations).Count
            observed_at        = [string]$snapshot.observed_at
        }
    } catch {
        return [ordered]@{ ok = $false; reason = $_.Exception.Message; worker = $Worker; cached = $false; observation_count = 0 }
    }
}

function Invoke-JournalRotation {
    <# Rename live journal to <name>.1 and start a fresh empty file. Keeps at most one
       rotation (overwrites prior .1). Never deletes live content without a rotation
       copy existing first. Machine-scoped: journals live once under BATON_HOME. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MaxBytes = $script:JournalRotateMaxBytes
    )
    $result = [ordered]@{ path = $Path; rotated = $false; reason = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            $result.reason = 'missing'
            return $result
        }
        $len = [long](Get-Item -LiteralPath $Path).Length
        if ($len -le $MaxBytes) {
            $result.reason = 'under_cap'
            $result.bytes = $len
            return $result
        }
        $rotatedPath = "$Path.1"
        if (Test-Path -LiteralPath $rotatedPath) {
            Remove-Item -LiteralPath $rotatedPath -Force -ErrorAction Stop
        }
        # Copy-then-truncate would risk losing the live file if copy fails mid-way;
        # Move preserves content, then a new empty live file is created.
        Move-Item -LiteralPath $Path -Destination $rotatedPath -Force -ErrorAction Stop
        Set-Content -LiteralPath $Path -Value '' -Encoding utf8NoBOM
        $result.rotated = $true
        $result.reason = 'rotated'
        $result.bytes = $len
        $result.rotated_path = $rotatedPath
        return $result
    } catch {
        $result.reason = $_.Exception.Message
        return $result
    }
}

function Invoke-HeartbeatJournalRotation {
    <# Free half: rotate all three machine-scoped journals once per beat. Never throws —
       a failed rotation is recorded so operators can see it without killing the beat. #>
    param(
        [string]$BatonHome = (Get-BatonHome),
        [long]$MaxBytes = $script:JournalRotateMaxBytes
    )
    $journalNames = @(
        'usage-journal.jsonl',
        'model-routing-log.md',
        'routing-journal.jsonl'
    )
    $rotations = [System.Collections.ArrayList]@()
    foreach ($name in $journalNames) {
        $jp = Join-Path $BatonHome $name
        try {
            $r = Invoke-JournalRotation -Path $jp -MaxBytes $MaxBytes
        } catch {
            $r = [ordered]@{ path = $jp; rotated = $false; reason = $_.Exception.Message }
        }
        [void]$rotations.Add($r)
    }
    return @($rotations.ToArray())
}

function Invoke-UsageHeartbeat {
    <# One beat: anchor (paid) + clear (free) + liveness (free) + probe refresh (free)
       + journal rotation (free), then advance the state. The free work runs even when
       the anchor fails — a login problem must not also leave the journal and the
       dashboard stale. #>
    param(
        [switch]$SkipAnchor,
        [string]$Model = 'haiku',
        [scriptblock]$Transport,
        [scriptblock]$ProbeTransport,
        [string]$BatonHome = (Get-BatonHome),
        [datetimeoffset]$Now = [datetimeoffset]::Now
    )
    $statePath = Get-HeartbeatStatePath -BatonHome $BatonHome
    $state = Read-HeartbeatState -Path $statePath
    $anchorResult = if ($SkipAnchor) {
        [ordered]@{ ok = $true; reason = 'skipped'; input_tokens = 0; output_tokens = 0; cost_usd = 0; spend_known = $true }
    } else {
        Invoke-AnchorHeartbeat -Model $Model -Transport $Transport
    }
    $cleared = @(Clear-ExpiredWorkerLockouts -UsagePath (Join-Path $BatonHome 'usage-journal.jsonl') -Now $Now.UtcDateTime)
    $liveness = Write-HeartbeatLiveness -BatonHome $BatonHome -Now $Now

    # Anchor Transport and ProbeTransport have different contracts; a hermetic suite
    # that injects only the anchor transport must not shell out to a real codex.
    $effectiveProbeTransport = $ProbeTransport
    if (-not $PSBoundParameters.ContainsKey('ProbeTransport') -and $Transport) {
        $effectiveProbeTransport = { param($clientVersion, $timeoutSeconds) $null }
    }
    $probeRefresh = Invoke-HeartbeatUsageProbeRefresh -BatonHome $BatonHome `
        -ProbeTransport $effectiveProbeTransport -Now $Now

    # Journals are machine-scoped (one set under BATON_HOME). Rotate once per beat here —
    # never from per-project hygiene, which races Move-Item when two projects service.
    $rotations = @(Invoke-HeartbeatJournalRotation -BatonHome $BatonHome)

    # Re-anchor ONLY when this beat actually started a new window — i.e. it fired at a
    # boundary. A manual mid-window beat consumes quota but does NOT move the real
    # boundary (the window is already running), so re-anchoring on it would corrupt the
    # schedule by pretending the window restarted. A failed anchor never re-anchors:
    # recording a window start that never happened is the same lie.
    $priorAnchor = if ($state.anchor) { Resolve-HeartbeatAnchor -Anchor ([string]$state.anchor) -Now $Now } else { $null }
    $lastFired = $null
    if ($state.last_fired_at) {
        try { $lastFired = [datetimeoffset]::Parse([string]$state.last_fired_at) } catch { $lastFired = $null }
    }
    $startedNewWindow = Test-HeartbeatOpensWindow -PriorAnchor $priorAnchor -LastFiredAt $lastFired -Now $Now

    # Only a beat that actually opened a window may move the anchor, and only if the
    # request succeeded. A failure or a --skip-anchor run records no window start —
    # inventing one would put every later boundary on a schedule nothing ran on.
    $realAnchorFired = $anchorResult.ok -and -not $SkipAnchor
    if ($realAnchorFired -and ($startedNewWindow -or -not $state.anchor)) {
        $state.anchor = $Now.ToString('o')
        $state.anchor_from_beat = $true
    }
    $state.last_beat_started_window = [bool]($realAnchorFired -and $startedNewWindow)
    $state.last_fired_at = $Now.ToString('o')
    $state.beats = [int]$state.beats + 1
    [void](Write-HeartbeatState -State $state -Path $statePath)

    # No anchor (a failed or skipped first beat planted none) -> no schedulable boundary.
    $anchorAt = if ([string]::IsNullOrWhiteSpace([string]$state.anchor)) { $null }
                else { Resolve-HeartbeatAnchor -Anchor ([string]$state.anchor) -Now $Now }
    $eps = Get-HeartbeatEpsilon -State $state
    $next = if ($anchorAt) { Get-NextHeartbeatBoundary -Anchor $anchorAt -Now $Now -EpsilonSeconds $eps } else { $null }
    return [ordered]@{
        fired_at        = $Now.ToString('o')
        anchor          = $anchorResult
        cleared_workers = $cleared
        liveness        = $liveness
        probe_refresh   = $probeRefresh
        rotations       = $rotations
        next            = $next
        state_path      = $statePath
    }
}

function Get-HeartbeatScheduleCommand {
    <# The schtasks argv that registers the NEXT one-shot beat. One-shot + self-reschedule
       (the runner re-registers after each beat) because a 5h cadence does not divide 24h,
       so no fixed daily time can express it. #>
    param(
        [Parameter(Mandatory)][datetimeoffset]$At,
        [string]$TaskName = 'BatonUsageHeartbeat',
        [string]$ScriptPath = (Join-Path $HOME '.claude/scripts/fleet-heartbeat.ps1')
    )
    $local = $At.ToLocalTime()
    return @(
        'schtasks', '/Create', '/F',
        '/TN', $TaskName,
        '/SC', 'ONCE',
        # InvariantCulture: '/' and ':' are culture-REPLACED separators in .NET custom
        # formats, so a de-DE box would emit '07.26.2026' and schtasks would take the
        # wrong day or refuse outright.
        '/ST', $local.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture),
        '/SD', $local.ToString('MM/dd/yyyy', [System.Globalization.CultureInfo]::InvariantCulture),
        '/TR', ('pwsh -NoProfile -WindowStyle Hidden -File "{0}" -Now -Reschedule' -f $ScriptPath)
    )
}
