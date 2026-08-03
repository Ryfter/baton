#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Window-aware token budgeting: fold model-routing-log.md into 5h + 7d consumption,
  optional headroom against window-budgets.json, and opt-in routing pressure.
.DESCRIPTION
  Read-only accounting over existing journals. No daemon, no polling, no background
  work — append-only reads, computed on demand. The 5h window reuses the heartbeat
  fixed-anchor grid; the 7d window is a rolling 168h. Budgets are optional: absent
  window-budgets.json means advisory-only (no invented caps, pressure = none).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/heartbeat-lib.ps1"   # Read-HeartbeatState, Resolve-HeartbeatAnchor, HeartbeatWindowHours
. "$PSScriptRoot/usage-lib.ps1"       # Read-UsageJournal, Get-WorkerState, ConvertTo-UsageDateTime

$script:WindowBudgetSoftPct = 70.0
$script:WindowBudgetHardPct = 90.0
$script:Window7dHours = 168

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

function Get-WindowBudgetsPath {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'window-budgets.json')
}

function Get-ModelRoutingLogPath {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'model-routing-log.md')
}

# ---------------------------------------------------------------------------
# Time helpers (defensive — never throw on junk)
# ---------------------------------------------------------------------------

function ConvertTo-WindowDateTime {
    <# Parse ISO-8601 / common timestamp to UTC DateTime; junk -> $null. #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return ([datetimeoffset]::Parse(
            $text.Trim(),
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        )).UtcDateTime
    } catch {
        try {
            return ([datetimeoffset]::Parse($text.Trim())).UtcDateTime
        } catch {
            return $null
        }
    }
}

function ConvertTo-WindowDateTimeOffset {
    <# Parse to DateTimeOffset; junk -> $null. #>
    param($Value, [datetimeoffset]$FallbackNow = [datetimeoffset]::Now)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) { return $Value }
    if ($Value -is [datetime]) {
        return [datetimeoffset]::new($Value.ToUniversalTime(), [timespan]::Zero)
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return [datetimeoffset]::Parse(
            $text.Trim(),
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        )
    } catch {
        try { return [datetimeoffset]::Parse($text.Trim()) } catch { return $null }
    }
}

function Resolve-WindowNow {
    param($Now)
    if ($null -eq $Now) { return [datetimeoffset]::Now }
    $dto = ConvertTo-WindowDateTimeOffset -Value $Now
    if ($null -eq $dto) { return [datetimeoffset]::Now }
    return $dto
}

# ---------------------------------------------------------------------------
# Part A — windows
# ---------------------------------------------------------------------------

function Get-UsageWindows {
    <# Current 5h (anchor grid) and 7d (rolling 168h) window bounds.
       Returns ordered hashtable with keys: now, '5h', '7d'.
       Each window: start, end, kind (anchored|rolling), hours. #>
    param(
        $Now,
        [string]$BatonHome = (Get-BatonHome)
    )
    $nowDto = Resolve-WindowNow -Now $Now
    $nowUtc = $nowDto.UtcDateTime

    # --- 5h: fixed-anchor grid (anchor + N*5h), else rolling fallback ---
    $windowHours = $script:HeartbeatWindowHours
    if ($null -eq $windowHours -or [double]$windowHours -le 0) { $windowHours = 5 }
    $windowSeconds = [double]($windowHours * 3600)

    $statePath = Get-HeartbeatStatePath -BatonHome $BatonHome
    $state = Read-HeartbeatState -Path $statePath
    $anchorDto = $null
    if ($state.anchor) {
        $anchorDto = Resolve-HeartbeatAnchor -Anchor ([string]$state.anchor) -Now $nowDto
        if ($null -eq $anchorDto) {
            $anchorDto = ConvertTo-WindowDateTimeOffset -Value $state.anchor
        }
    }

    $win5 = $null
    if ($null -ne $anchorDto) {
        $elapsed = ($nowDto - $anchorDto).TotalSeconds
        if ($elapsed -lt 0) {
            # Anchor still ahead: current open window is the one ending at the first boundary.
            $startDto = $anchorDto.AddSeconds(-$windowSeconds)
            $endDto = $anchorDto
        } else {
            $n = [math]::Floor($elapsed / $windowSeconds)
            $startDto = $anchorDto.AddSeconds($n * $windowSeconds)
            $endDto = $startDto.AddSeconds($windowSeconds)
        }
        $win5 = [ordered]@{
            start          = $startDto.UtcDateTime
            end            = $endDto.UtcDateTime
            start_offset   = $startDto.ToString('o')
            end_offset     = $endDto.ToString('o')
            kind           = 'anchored'
            hours          = [double]$windowHours
            anchor         = $anchorDto.ToString('o')
            fallback       = $false
        }
    } else {
        $startUtc = $nowUtc.AddHours(-[double]$windowHours)
        $win5 = [ordered]@{
            start          = $startUtc
            end            = $nowUtc
            start_offset   = ([datetimeoffset]::new($startUtc, [timespan]::Zero)).ToString('o')
            end_offset     = $nowDto.ToString('o')
            kind           = 'rolling'
            hours          = [double]$windowHours
            anchor         = $null
            fallback       = $true
            fallback_reason = 'no heartbeat anchor; using rolling 5h ending at now'
        }
    }

    # --- 7d: always rolling 168h ending at Now ---
    $h7 = [double]$script:Window7dHours
    $start7 = $nowUtc.AddHours(-$h7)
    $win7 = [ordered]@{
        start        = $start7
        end          = $nowUtc
        start_offset = ([datetimeoffset]::new($start7, [timespan]::Zero)).ToString('o')
        end_offset   = $nowDto.ToString('o')
        kind         = 'rolling'
        hours        = $h7
        fallback     = $false
    }

    return [ordered]@{
        now   = $nowUtc
        now_o = $nowDto.ToString('o')
        '5h'  = $win5
        '7d'  = $win7
    }
}

# ---------------------------------------------------------------------------
# Journal parsing (model-routing-log.md)
# ---------------------------------------------------------------------------

function Parse-ModelRoutingLine {
    <# Parse one model-routing-log line into a dispatch row, or $null to skip.
       Skips notes, headers, lines without tok:, and unparseable timestamps. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $trim = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($trim)) { return $null }
    if ($trim.StartsWith('#') -or $trim.StartsWith('>')) { return $null }

    $fields = @($trim -split '\s*\|\s*')
    if ($fields.Count -lt 3) { return $null }

    $source = [string]$fields[1]
    if ($source -eq 'note') { return $null }

    # Require tok:N(exact|estimate) somewhere — lines without token data are not consumption.
    $tokens = $null
    $basis = $null
    $tokField = $null
    foreach ($f in $fields) {
        if ($f -match '^tok:(\d+)\((exact|estimate)\)$') {
            $tokens = [long]$Matches[1]
            $basis = [string]$Matches[2]
            $tokField = $f
            break
        }
    }
    if ($null -eq $tokens) { return $null }

    $ts = ConvertTo-WindowDateTime -Value $fields[0]
    if ($null -eq $ts) { return $null }

    $model = [string]$fields[2]
    if ([string]::IsNullOrWhiteSpace($model)) { return $null }

    $seconds = 0
    if ($fields.Count -gt 3 -and $fields[3] -match '^(\d+)s$') {
        $seconds = [int]$Matches[1]
    }

    $job = ''
    $phase = ''
    $project = ''
    $originHost = ''
    for ($i = 4; $i -lt $fields.Count; $i++) {
        $f = [string]$fields[$i]
        if ($f -match '^host:(.+)$') { $originHost = $Matches[1]; continue }
        if ($f -match '^job:(.+)$') { $job = $Matches[1]; continue }
        if ($f -match '^phase:(.+)$') { $phase = $Matches[1]; continue }
        if ($f -match '^project:(.+)$') { $project = $Matches[1]; continue }
    }

    return [ordered]@{
        ts             = $ts
        source         = $source
        model          = $model
        seconds        = $seconds
        tokens         = $tokens
        tokens_basis   = $basis
        job            = $job
        phase          = $phase
        project        = $project
        host           = $originHost
        raw            = $trim
    }
}

function Read-ModelRoutingDispatchRows {
    <# Read model-routing-log.md into dispatch rows. Also returns parse diagnostics. #>
    param(
        [string]$Path = (Get-ModelRoutingLogPath),
        [ref]$Diagnostics
    )
    $diag = [ordered]@{
        path              = $Path
        exists            = $false
        lines_total       = 0
        lines_parsed      = 0
        lines_skipped     = 0
        lines_unparsable  = 0
        lines_no_tok      = 0
        lines_note        = 0
        lines_bad_ts      = 0
    }
    $rows = [System.Collections.ArrayList]@()
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        if ($Diagnostics) { $Diagnostics.Value = $diag }
        return @()
    }
    $diag.exists = $true
    try {
        $allLines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    } catch {
        $diag.lines_unparsable = -1
        if ($Diagnostics) { $Diagnostics.Value = $diag }
        return @()
    }
    $diag.lines_total = $allLines.Count
    foreach ($line in $allLines) {
        $trim = if ($null -eq $line) { '' } else { $line.Trim() }
        if ([string]::IsNullOrWhiteSpace($trim) -or $trim.StartsWith('#') -or $trim.StartsWith('>')) {
            $diag.lines_skipped++
            continue
        }
        $fields = @($trim -split '\s*\|\s*')
        if ($fields.Count -ge 2 -and [string]$fields[1] -eq 'note') {
            $diag.lines_note++
            $diag.lines_skipped++
            continue
        }
        $hasTok = $false
        foreach ($f in $fields) {
            if ($f -match '^tok:\d+\((exact|estimate)\)$') { $hasTok = $true; break }
        }
        if (-not $hasTok) {
            $diag.lines_no_tok++
            $diag.lines_skipped++
            continue
        }
        $tsProbe = ConvertTo-WindowDateTime -Value $fields[0]
        if ($null -eq $tsProbe) {
            $diag.lines_bad_ts++
            $diag.lines_unparsable++
            $diag.lines_skipped++
            continue
        }
        $parsed = Parse-ModelRoutingLine -Line $trim
        if ($null -eq $parsed) {
            $diag.lines_unparsable++
            $diag.lines_skipped++
            continue
        }
        [void]$rows.Add([pscustomobject]$parsed)
        $diag.lines_parsed++
    }
    if ($Diagnostics) { $Diagnostics.Value = $diag }
    return @($rows.ToArray())
}

function Resolve-JobProjectMap {
    <# Optional job_id -> project slug from BATON_HOME/jobs/*/manifest.yaml (best-effort). #>
    param([string]$BatonHome = (Get-BatonHome))
    $map = @{}
    $jobsRoot = Join-Path $BatonHome 'jobs'
    if (-not (Test-Path -LiteralPath $jobsRoot)) { return $map }
    try {
        $manifests = @(Get-ChildItem -LiteralPath $jobsRoot -Recurse -Filter 'manifest.yaml' -ErrorAction SilentlyContinue)
    } catch { return $map }
    foreach ($mf in $manifests) {
        try {
            $jobId = $null
            $project = $null
            foreach ($rawLine in (Get-Content -LiteralPath $mf.FullName -ErrorAction SilentlyContinue)) {
                if ($rawLine -match '^\s*id:\s*(.+?)\s*$') {
                    $jobId = $Matches[1].Trim().Trim('"', "'")
                }
                if ($rawLine -match '^\s*project:\s*(.+?)\s*$') {
                    $project = $Matches[1].Trim().Trim('"', "'")
                }
            }
            if ($jobId -and $project) { $map[$jobId] = $project }
        } catch { }
    }
    return $map
}

function Test-DispatchProjectMatch {
    param(
        $Row,
        [string]$Project,
        [hashtable]$JobProjectMap
    )
    if ([string]::IsNullOrWhiteSpace($Project)) { return $true }
    $slug = $Project.Trim()
    if ($Row.project -and ([string]$Row.project -eq $slug)) { return $true }
    if ($Row.job -and $JobProjectMap -and $JobProjectMap.ContainsKey([string]$Row.job)) {
        return ([string]$JobProjectMap[[string]$Row.job] -eq $slug)
    }
    # job id itself sometimes embeds the project slug
    if ($Row.job -and ([string]$Row.job -match [regex]::Escape($slug))) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Consumption fold
# ---------------------------------------------------------------------------

function Get-WindowConsumption {
    <# Per-model token/dispatch/time rows for one window (5h or 7d).
       exact_tokens and estimated_tokens are reported separately; tokens is their sum. #>
    param(
        [Parameter(Mandatory)][ValidateSet('5h', '7d')][string]$Window,
        [string]$Project,
        $Now,
        [string]$BatonHome = (Get-BatonHome),
        [string]$JournalPath,
        [object[]]$Rows,
        $Windows
    )
    if (-not $JournalPath) { $JournalPath = Get-ModelRoutingLogPath -BatonHome $BatonHome }
    if (-not $Windows) { $Windows = Get-UsageWindows -Now $Now -BatonHome $BatonHome }
    $bounds = $Windows[$Window]
    $startUtc = [datetime]$bounds.start
    $endUtc = [datetime]$bounds.end

    if (-not $PSBoundParameters.ContainsKey('Rows')) {
        $Rows = @(Read-ModelRoutingDispatchRows -Path $JournalPath)
    }
    $jobMap = @{}
    if ($Project) { $jobMap = Resolve-JobProjectMap -BatonHome $BatonHome }

    $byModel = @{}
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $ts = $row.ts
        if ($ts -isnot [datetime]) { $ts = ConvertTo-WindowDateTime -Value $ts }
        if ($null -eq $ts) { continue }
        if ($ts -lt $startUtc -or $ts -gt $endUtc) { continue }
        if (-not (Test-DispatchProjectMatch -Row $row -Project $Project -JobProjectMap $jobMap)) { continue }

        $model = [string]$row.model
        if (-not $byModel.ContainsKey($model)) {
            $byModel[$model] = [ordered]@{
                model             = $model
                tokens            = [long]0
                dispatches        = 0
                seconds           = [long]0
                exact_tokens      = [long]0
                estimated_tokens  = [long]0
            }
        }
        $acc = $byModel[$model]
        $tok = [long]$row.tokens
        $acc.tokens += $tok
        $acc.dispatches += 1
        $acc.seconds += [long]$row.seconds
        if ([string]$row.tokens_basis -eq 'exact') {
            $acc.exact_tokens += $tok
        } else {
            $acc.estimated_tokens += $tok
        }
    }

    $list = [System.Collections.ArrayList]@()
    foreach ($v in ($byModel.Values | Sort-Object { $_.tokens } -Descending)) {
        [void]$list.Add([pscustomobject]$v)
    }
    # Unary-comma keeps a single-element (or empty) list from unrolling on assignment.
    return ,([object[]]$list.ToArray())
}

function Read-WindowBudgets {
    <# Optional $BATON_HOME/window-budgets.json.
       Shape: { "<model>": { "tokens_5h": N, "tokens_7d": N } }
       Absent/corrupt -> empty hashtable (advisory only; never invent caps). #>
    param([string]$Path = (Get-WindowBudgetsPath))
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $result
    }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $result
    }
    if ($null -eq $doc) { return $result }
    foreach ($prop in $doc.PSObject.Properties) {
        $name = [string]$prop.Name
        if ($name.StartsWith('_')) { continue }   # reserved meta keys
        $val = $prop.Value
        if ($null -eq $val) { continue }
        $t5 = $null
        $t7 = $null
        if ($null -ne $val.tokens_5h -and "$($val.tokens_5h)" -match '^\d+$') {
            $t5 = [long]$val.tokens_5h
        }
        if ($null -ne $val.tokens_7d -and "$($val.tokens_7d)" -match '^\d+$') {
            $t7 = [long]$val.tokens_7d
        }
        if ($null -eq $t5 -and $null -eq $t7) { continue }
        $result[$name] = [ordered]@{
            tokens_5h = $t5
            tokens_7d = $t7
        }
    }
    return $result
}

function Get-ModelHeadroom {
    <# Consumption in both windows + optional budget headroom + active lockout/reset_at. #>
    param(
        [Parameter(Mandatory)][string]$Model,
        $Now,
        [string]$BatonHome = (Get-BatonHome),
        [string]$JournalPath,
        [string]$BudgetsPath,
        [string]$UsagePath,
        [object[]]$DispatchRows,
        $Windows,
        [hashtable]$Budgets
    )
    if (-not $JournalPath) { $JournalPath = Get-ModelRoutingLogPath -BatonHome $BatonHome }
    if (-not $BudgetsPath) { $BudgetsPath = Get-WindowBudgetsPath -BatonHome $BatonHome }
    if (-not $UsagePath) { $UsagePath = Join-Path $BatonHome 'usage-journal.jsonl' }
    if (-not $Windows) { $Windows = Get-UsageWindows -Now $Now -BatonHome $BatonHome }
    if (-not $PSBoundParameters.ContainsKey('DispatchRows')) {
        $DispatchRows = @(Read-ModelRoutingDispatchRows -Path $JournalPath)
    }
    if (-not $PSBoundParameters.ContainsKey('Budgets')) {
        $Budgets = Read-WindowBudgets -Path $BudgetsPath
    }

    $c5 = Get-WindowConsumption -Window '5h' -Now $Now -BatonHome $BatonHome `
        -JournalPath $JournalPath -Rows $DispatchRows -Windows $Windows
    $c7 = Get-WindowConsumption -Window '7d' -Now $Now -BatonHome $BatonHome `
        -JournalPath $JournalPath -Rows $DispatchRows -Windows $Windows

    $row5 = $c5 | Where-Object { $_.model -eq $Model } | Select-Object -First 1
    $row7 = $c7 | Where-Object { $_.model -eq $Model } | Select-Object -First 1
    $emptyRow = [pscustomobject][ordered]@{
        model = $Model; tokens = [long]0; dispatches = 0; seconds = [long]0
        exact_tokens = [long]0; estimated_tokens = [long]0
    }
    $cons5 = if ($null -ne $row5) { $row5 } else { $emptyRow }
    $cons7 = if ($null -ne $row7) { $row7 } else { $emptyRow }

    $budget = $null
    $headroomPct = $null
    $usedPct = $null
    if ($Budgets -and $Budgets.ContainsKey($Model)) {
        $b = $Budgets[$Model]
        $budget = [ordered]@{
            tokens_5h = $b.tokens_5h
            tokens_7d = $b.tokens_7d
        }
        $hp = [ordered]@{}
        $up = [ordered]@{}
        if ($null -ne $b.tokens_5h -and [long]$b.tokens_5h -gt 0) {
            $used5 = [math]::Min(100.0, [math]::Round(([long]$cons5.tokens / [long]$b.tokens_5h) * 100.0, 1))
            $up['5h'] = $used5
            $hp['5h'] = [math]::Round(100.0 - $used5, 1)
        } else {
            $up['5h'] = $null
            $hp['5h'] = $null
        }
        if ($null -ne $b.tokens_7d -and [long]$b.tokens_7d -gt 0) {
            $used7 = [math]::Min(100.0, [math]::Round(([long]$cons7.tokens / [long]$b.tokens_7d) * 100.0, 1))
            $up['7d'] = $used7
            $hp['7d'] = [math]::Round(100.0 - $used7, 1)
        } else {
            $up['7d'] = $null
            $hp['7d'] = $null
        }
        $headroomPct = $hp
        $usedPct = $up
    }

    $lockout = [ordered]@{
        active   = $false
        state    = 'available'
        reset_at = $null
        reason   = $null
    }
    try {
        $nowDt = if ($null -ne $Windows.now) { [datetime]$Windows.now } else { [datetime]::UtcNow }
        $st = Get-WorkerState -Worker $Model -UsagePath $UsagePath -Now $nowDt
        $lockout.state = [string]$st.state
        $lockout.reset_at = $st.reset_at
        $lockout.reason = $st.reason
        if ($st.state -in @('exhausted', 'waiting_for_reset', 'cooling_down', 'limited')) {
            $lockout.active = $true
        }
    } catch { }

    return [ordered]@{
        model          = $Model
        window_5h      = $cons5
        window_7d      = $cons7
        bounds_5h      = $Windows['5h']
        bounds_7d      = $Windows['7d']
        budget         = $budget
        headroom_pct   = $headroomPct
        used_pct       = $usedPct
        lockout        = $lockout
    }
}

# ---------------------------------------------------------------------------
# Part C — pressure (opt-in at the routing seam)
# ---------------------------------------------------------------------------

function Get-WindowPressureThresholds {
    param([string]$BudgetsPath = (Get-WindowBudgetsPath))
    $soft = [double]$script:WindowBudgetSoftPct
    $hard = [double]$script:WindowBudgetHardPct
    # Optional reserved meta in the budgets file:
    #   "_thresholds": { "soft_pct": 70, "hard_pct": 90 }
    if ($BudgetsPath -and (Test-Path -LiteralPath $BudgetsPath)) {
        try {
            $doc = Get-Content -LiteralPath $BudgetsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($doc._thresholds) {
                if ($null -ne $doc._thresholds.soft_pct) { $soft = [double]$doc._thresholds.soft_pct }
                if ($null -ne $doc._thresholds.hard_pct) { $hard = [double]$doc._thresholds.hard_pct }
            }
        } catch { }
    }
    if ($env:BATON_WINDOW_SOFT_PCT -match '^\d+(\.\d+)?$') { $soft = [double]$env:BATON_WINDOW_SOFT_PCT }
    if ($env:BATON_WINDOW_HARD_PCT -match '^\d+(\.\d+)?$') { $hard = [double]$env:BATON_WINDOW_HARD_PCT }
    return [ordered]@{ soft_pct = $soft; hard_pct = $hard }
}

function Get-WindowPressure {
    <# none | soft | hard from configured budgets.
       Absence of budget/data MUST return none — never invent a cap. #>
    param(
        [Parameter(Mandatory)][string]$Model,
        $Now,
        [string]$BatonHome = (Get-BatonHome),
        [string]$BudgetsPath,
        [string]$JournalPath,
        [string]$UsagePath,
        $Headroom
    )
    if (-not $BudgetsPath) { $BudgetsPath = Get-WindowBudgetsPath -BatonHome $BatonHome }
    $budgets = Read-WindowBudgets -Path $BudgetsPath
    if (-not $budgets.ContainsKey($Model)) { return 'none' }

    if (-not $Headroom) {
        $Headroom = Get-ModelHeadroom -Model $Model -Now $Now -BatonHome $BatonHome `
            -BudgetsPath $BudgetsPath -JournalPath $JournalPath -UsagePath $UsagePath `
            -Budgets $budgets
    }
    if ($null -eq $Headroom.used_pct) { return 'none' }

    $th = Get-WindowPressureThresholds -BudgetsPath $BudgetsPath
    $maxUsed = $null
    foreach ($key in @('5h', '7d')) {
        $u = $Headroom.used_pct[$key]
        if ($null -eq $u) { continue }
        if ($null -eq $maxUsed -or [double]$u -gt $maxUsed) { $maxUsed = [double]$u }
    }
    if ($null -eq $maxUsed) { return 'none' }
    if ($maxUsed -ge [double]$th.hard_pct) { return 'hard' }
    if ($maxUsed -ge [double]$th.soft_pct) { return 'soft' }
    return 'none'
}

function Test-WindowPressureEnabled {
    <# Gate: BATON_WINDOW_PRESSURE=on enables; anything else (incl. unset) is off. #>
    $v = [string]$env:BATON_WINDOW_PRESSURE
    if ([string]::IsNullOrWhiteSpace($v)) { return $false }
    return ($v.Trim().ToLowerInvariant() -eq 'on')
}

function Get-WindowPressureAdjust {
    <# Rank penalty folded into Get-LearnedTierRank-style sort.
       soft = +0.5 (loses same-tier ties); hard = +2.0 (strong de-rank).
       never removes a candidate. #>
    param([ValidateSet('none', 'soft', 'hard')][string]$Pressure = 'none')
    switch ($Pressure) {
        'soft' { return 0.5 }
        'hard' { return 2.0 }
        default { return 0.0 }
    }
}

function Write-WindowPressureJournalLine {
    <# Append one JSONL note explaining a pressure-driven rank adjustment. Fail-soft. #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Pressure,
        [string]$Reason,
        [string]$Capability,
        [double]$Adjust = 0.0,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'),
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToString('o') }
    $row = [ordered]@{
        ts         = $Timestamp
        event      = 'window_pressure'
        candidate  = $Model
        pressure   = $Pressure
        adjust     = $Adjust
        reason     = $(if ($Reason) { $Reason } else { "window-pressure $Pressure de-rank" })
    }
    if ($Capability) { $row['capability'] = $Capability }
    try {
        $dir = Split-Path -Parent $JournalPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Add-Content -LiteralPath $JournalPath -Value ($row | ConvertTo-Json -Compress -Depth 4) -Encoding utf8NoBOM
    } catch {
        Write-Warning "window-pressure journal write failed: $($_.Exception.Message)"
    }
}

function Apply-WindowPressureToCandidates {
    <# Tag candidates with window_pressure + window_pressure_adjust; journal each
       non-none adjustment. Does not drop candidates. No-op when gate is off. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [string]$Capability,
        [string]$BatonHome = (Get-BatonHome),
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'),
        $Now
    )
    if (-not (Test-WindowPressureEnabled)) {
        return ,([object[]]@($Candidates))
    }
    $out = foreach ($c in @($Candidates)) {
        if ($null -eq $c) { continue }
        $c | Add-Member -NotePropertyName window_pressure -NotePropertyValue 'none' -Force
        $c | Add-Member -NotePropertyName window_pressure_adjust -NotePropertyValue 0.0 -Force
        $modelName = [string]$c.name
        if ([string]::IsNullOrWhiteSpace($modelName)) { $c; continue }
        try {
            $pressure = Get-WindowPressure -Model $modelName -Now $Now -BatonHome $BatonHome
        } catch {
            $pressure = 'none'
        }
        $c.window_pressure = $pressure
        $adj = Get-WindowPressureAdjust -Pressure $pressure
        $c.window_pressure_adjust = $adj
        if ($pressure -ne 'none' -and $adj -ne 0.0) {
            $reason = "window-pressure ${pressure}: de-ranked by $adj to conserve budget headroom"
            if ($c.why) { $c.why = "$($c.why); $reason" } else { $c.why = $reason }
            Write-WindowPressureJournalLine -Model $modelName -Pressure $pressure `
                -Reason $reason -Capability $Capability -Adjust $adj -JournalPath $JournalPath
        }
        $c
    }
    return ,([object[]]@($out))
}

# ---------------------------------------------------------------------------
# Status / doctor aggregates (used by CLI)
# ---------------------------------------------------------------------------

function Get-WindowBudgetStatus {
    <# Full status object for budget status CLI. #>
    param(
        [ValidateSet('5h', '7d', 'both')][string]$Window = 'both',
        [string]$Project,
        $Now,
        [string]$BatonHome = (Get-BatonHome)
    )
    $windows = Get-UsageWindows -Now $Now -BatonHome $BatonHome
    $diag = $null
    $journalPath = Get-ModelRoutingLogPath -BatonHome $BatonHome
    $rows = @(Read-ModelRoutingDispatchRows -Path $journalPath -Diagnostics ([ref]$diag))
    $budgets = Read-WindowBudgets -Path (Get-WindowBudgetsPath -BatonHome $BatonHome)
    $budgetsExist = Test-Path -LiteralPath (Get-WindowBudgetsPath -BatonHome $BatonHome)

    $want5 = ($Window -eq '5h' -or $Window -eq 'both')
    $want7 = ($Window -eq '7d' -or $Window -eq 'both')

    $models = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $cons5 = @()
    $cons7 = @()
    if ($want5) {
        $cons5 = Get-WindowConsumption -Window '5h' -Project $Project -Now $Now `
            -BatonHome $BatonHome -Rows $rows -Windows $windows
        foreach ($r in @($cons5)) { if ($null -ne $r) { [void]$models.Add([string]$r.model) } }
    }
    if ($want7) {
        $cons7 = Get-WindowConsumption -Window '7d' -Project $Project -Now $Now `
            -BatonHome $BatonHome -Rows $rows -Windows $windows
        foreach ($r in @($cons7)) { if ($null -ne $r) { [void]$models.Add([string]$r.model) } }
    }
    foreach ($k in $budgets.Keys) { [void]$models.Add([string]$k) }

    $modelRows = foreach ($m in ($models | Sort-Object)) {
        $h = Get-ModelHeadroom -Model $m -Now $Now -BatonHome $BatonHome `
            -DispatchRows $rows -Windows $windows -Budgets $budgets
        $pressure = if ($budgets.ContainsKey($m)) {
            Get-WindowPressure -Model $m -Now $Now -BatonHome $BatonHome -Headroom $h
        } else { 'none' }
        [ordered]@{
            model            = $m
            tokens_5h        = [long]$h.window_5h.tokens
            dispatches_5h    = [int]$h.window_5h.dispatches
            seconds_5h       = [long]$h.window_5h.seconds
            exact_tokens_5h  = [long]$h.window_5h.exact_tokens
            estimated_tokens_5h = [long]$h.window_5h.estimated_tokens
            tokens_7d        = [long]$h.window_7d.tokens
            dispatches_7d    = [int]$h.window_7d.dispatches
            seconds_7d       = [long]$h.window_7d.seconds
            exact_tokens_7d  = [long]$h.window_7d.exact_tokens
            estimated_tokens_7d = [long]$h.window_7d.estimated_tokens
            budget           = $h.budget
            headroom_pct     = $h.headroom_pct
            used_pct         = $h.used_pct
            pressure         = $pressure
            lockout          = $h.lockout
        }
    }

    return [ordered]@{
        now                 = $windows.now_o
        window              = $Window
        project             = $Project
        windows             = [ordered]@{ '5h' = $windows['5h']; '7d' = $windows['7d'] }
        pressure_enabled    = (Test-WindowPressureEnabled)
        budgets_file        = (Get-WindowBudgetsPath -BatonHome $BatonHome)
        budgets_configured  = $budgetsExist
        journal             = $diag
        models              = @($modelRows)
    }
}

function Get-WindowBudgetDoctor {
    <# Surface what cannot be computed and why — silence must never mean "all good". #>
    param(
        $Now,
        [string]$BatonHome = (Get-BatonHome)
    )
    $issues = [System.Collections.ArrayList]@()
    $windows = Get-UsageWindows -Now $Now -BatonHome $BatonHome
    if ([bool]$windows['5h'].fallback) {
        [void]$issues.Add([ordered]@{
            code    = 'no_anchor'
            severity = 'warn'
            message = 'No heartbeat anchor; 5h window is rolling fallback (not the fixed grid).'
            detail  = $windows['5h'].fallback_reason
        })
    }
    $bp = Get-WindowBudgetsPath -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $bp)) {
        [void]$issues.Add([ordered]@{
            code     = 'no_budgets_file'
            severity = 'info'
            message  = 'No window-budgets.json — headroom and pressure are advisory-only (no caps).'
            detail   = $bp
        })
    } else {
        $b = Read-WindowBudgets -Path $bp
        if ($b.Count -eq 0) {
            [void]$issues.Add([ordered]@{
                code     = 'empty_budgets'
                severity = 'warn'
                message  = 'window-budgets.json present but no model budgets parsed.'
                detail   = $bp
            })
        }
    }
    $jp = Get-ModelRoutingLogPath -BatonHome $BatonHome
    $diag = $null
    [void](Read-ModelRoutingDispatchRows -Path $jp -Diagnostics ([ref]$diag))
    if (-not $diag.exists) {
        [void]$issues.Add([ordered]@{
            code     = 'no_journal'
            severity = 'warn'
            message  = 'model-routing-log.md missing — consumption is zero for every model.'
            detail   = $jp
        })
    } else {
        if ([int]$diag.lines_unparsable -gt 0) {
            [void]$issues.Add([ordered]@{
                code     = 'unparsable_lines'
                severity = 'warn'
                message  = ("{0} journal line(s) had tok: but could not be folded (bad timestamp or shape)." -f $diag.lines_unparsable)
                detail   = $diag
            })
        }
        if ([int]$diag.lines_parsed -eq 0 -and [int]$diag.lines_total -gt 0) {
            [void]$issues.Add([ordered]@{
                code     = 'no_token_lines'
                severity = 'info'
                message  = 'Journal has lines but none with tok:N(exact|estimate) — nothing to fold.'
                detail   = $diag
            })
        }
    }
    if (-not (Test-WindowPressureEnabled)) {
        [void]$issues.Add([ordered]@{
            code     = 'pressure_off'
            severity = 'info'
            message  = 'BATON_WINDOW_PRESSURE is not on — routing rank is unchanged by window headroom.'
            detail   = "BATON_WINDOW_PRESSURE=$([string]$env:BATON_WINDOW_PRESSURE)"
        })
    }

    $ok = (@($issues | Where-Object { $_.severity -in @('warn', 'error') }).Count -eq 0)
    return [ordered]@{
        ok       = $ok
        now      = $windows.now_o
        windows  = [ordered]@{ '5h' = $windows['5h']; '7d' = $windows['7d'] }
        journal  = $diag
        issues   = @($issues.ToArray())
    }
}
