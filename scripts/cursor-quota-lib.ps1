#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Read Cursor Pro billing-cycle usage from api2.cursor.sh and cache under BATON_HOME.
  Display knobs live in $BATON_HOME/cursor-quota.config.json (seeded from references/).
#>
. (Join-Path $PSScriptRoot 'baton-home.ps1')

function Get-CursorStateDbPath {
    if ($IsWindows) {
        return (Join-Path $env:APPDATA 'Cursor/User/globalStorage/state.vscdb')
    }
    if ($IsMacOS) {
        return (Join-Path $HOME 'Library/Application Support/Cursor/User/globalStorage/state.vscdb')
    }
    return (Join-Path $HOME '.config/Cursor/User/globalStorage/state.vscdb')
}

function Get-CursorQuotaCachePath {
    param([string]$BatonHome = $(Get-BatonHome))
    return (Join-Path $BatonHome 'cursor-quota.json')
}

function Get-CursorQuotaConfigPath {
    param([string]$BatonHome = $(Get-BatonHome))
    return (Join-Path $BatonHome 'cursor-quota.config.json')
}

function Get-CursorQuotaConfig {
    param([string]$BatonHome = $(Get-BatonHome))
    $defaults = [ordered]@{
        cache_ttl_seconds = 300
        api_url           = 'https://api2.cursor.sh/auth/usage-summary'
        display           = [ordered]@{
            statusline_format = 'ansi'
            room_format       = 'detail'
            show_auto_api     = $true
            bar_width         = 10
            yellow_pct        = 70
            red_pct           = 90
        }
    }
    $path = Get-CursorQuotaConfigPath -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $path)) { return $defaults }
    try {
        $user = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($user.cache_ttl_seconds) { $defaults.cache_ttl_seconds = [int]$user.cache_ttl_seconds }
        if ($user.api_url) { $defaults.api_url = [string]$user.api_url }
        if ($user.display) {
            foreach ($k in @('statusline_format', 'room_format')) {
                if ($user.display.PSObject.Properties.Name -contains $k) {
                    $defaults.display[$k] = [string]$user.display.$k
                }
            }
            foreach ($k in @('show_auto_api')) {
                if ($user.display.PSObject.Properties.Name -contains $k) {
                    $defaults.display[$k] = [bool]$user.display.$k
                }
            }
            foreach ($k in @('bar_width', 'yellow_pct', 'red_pct')) {
                if ($user.display.PSObject.Properties.Name -contains $k) {
                    $defaults.display[$k] = [int]$user.display.$k
                }
            }
        }
    } catch { }
    return $defaults
}

function Get-CursorAccessToken {
    param([string]$StateDbPath = $(Get-CursorStateDbPath))
    if (-not (Test-Path -LiteralPath $StateDbPath)) { return $null }
    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite) { return $null }
    try {
        $tok = & $sqlite.Source $StateDbPath "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';" 2>$null
        $tok = if ($null -eq $tok) { '' } else { [string]$tok.Trim() }
        if ($tok.Length -lt 8) { return $null }
        return $tok
    } catch {
        return $null
    }
}

function ConvertTo-CursorBillingIso {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime().ToString('o')
    }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o')
    }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    try {
        return [datetimeoffset]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).ToString('o')
    } catch { }
    try {
        return [datetimeoffset]::Parse($s).ToUniversalTime().ToString('o')
    } catch { }
    return $s
}

function Get-CursorBillingDaysLeft {
    param([string]$CycleEndIso)
    if ([string]::IsNullOrWhiteSpace($CycleEndIso)) { return $null }
    try {
        $endDt = [datetimeoffset]::Parse($CycleEndIso, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
        return [Math]::Max(0, [int][Math]::Ceiling(($endDt.UtcDateTime - [datetime]::UtcNow).TotalDays))
    } catch {
        return $null
    }
}

function ConvertTo-CursorQuotaRecord {
    param(
        $Summary,
        [ValidateSet('ok', 'stale', 'unavailable')][string]$FetchStatus = 'ok'
    )
    if (-not $Summary) { return $null }
    $plan = $Summary.individualUsage.plan
    if (-not $plan) { return $null }
    $startIso = ConvertTo-CursorBillingIso $Summary.billingCycleStart
    $endIso = ConvertTo-CursorBillingIso $Summary.billingCycleEnd
    $total = [double]$plan.totalPercentUsed
    $remaining = [Math]::Max(0.0, [Math]::Round(100.0 - $total, 1))
    return [ordered]@{
        schema              = 1
        observed_at         = (Get-Date).ToUniversalTime().ToString('o')
        fetch_status        = $FetchStatus
        billing_cycle_start = $startIso
        billing_cycle_end   = $endIso
        days_left           = (Get-CursorBillingDaysLeft -CycleEndIso $endIso)
        membership_type     = [string]$Summary.membershipType
        total_used_pct      = $total
        remaining_pct       = $remaining
        auto_used_pct       = if ($null -ne $plan.autoPercentUsed) { [double]$plan.autoPercentUsed } else { $null }
        api_used_pct        = if ($null -ne $plan.apiPercentUsed) { [double]$plan.apiPercentUsed } else { $null }
        on_demand_enabled   = [bool]$Summary.individualUsage.onDemand.enabled
    }
}

function Read-CursorQuotaCache {
    param([string]$Path = $(Get-CursorQuotaCachePath))
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Read-ClaudeQuotaCache {
    param([string]$BatonHome = $(Get-BatonHome))
    $path = Join-Path $BatonHome 'claude-quota.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-CursorQuotaCacheFresh {
    param(
        $Cache,
        [int]$MaxAgeSeconds = 300
    )
    if (-not $Cache -or -not $Cache.observed_at) { return $false }
    try {
        $obs = [datetimeoffset]::Parse([string]$Cache.observed_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $age = ([datetime]::UtcNow - $obs.UtcDateTime).TotalSeconds
        return ($age -ge 0 -and $age -lt $MaxAgeSeconds)
    } catch {
        return $false
    }
}

function Invoke-CursorUsageSummary {
    param(
        [string]$Token,
        [string]$ApiUrl = 'https://api2.cursor.sh/auth/usage-summary'
    )
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    try {
        return (Invoke-RestMethod -Uri $ApiUrl -Headers @{ Authorization = "Bearer $Token" } -Method Get -TimeoutSec 8)
    } catch {
        return $null
    }
}

function Update-CursorQuotaCache {
    param(
        [int]$MaxAgeSeconds = 0,
        [string]$CachePath = $(Get-CursorQuotaCachePath),
        [string]$StateDbPath = $(Get-CursorStateDbPath),
        [string]$BatonHome = $(Get-BatonHome),
        $Summary,
        [switch]$Force
    )
    $cfg = Get-CursorQuotaConfig -BatonHome $BatonHome
    if ($MaxAgeSeconds -le 0) { $MaxAgeSeconds = [int]$cfg.cache_ttl_seconds }
    $cached = Read-CursorQuotaCache -Path $CachePath
    if (-not $Force -and (Test-CursorQuotaCacheFresh -Cache $cached -MaxAgeSeconds $MaxAgeSeconds)) {
        return $cached
    }
    if (-not $Summary) {
        $token = Get-CursorAccessToken -StateDbPath $StateDbPath
        $Summary = Invoke-CursorUsageSummary -Token $token -ApiUrl ([string]$cfg.api_url)
    }
    $rec = ConvertTo-CursorQuotaRecord -Summary $Summary -FetchStatus 'ok'
    if (-not $rec) {
        if ($cached) {
            if (-not $cached.PSObject.Properties.Name -contains 'fetch_status') {
                $cached | Add-Member -NotePropertyName fetch_status -NotePropertyValue 'stale' -Force
            } else {
                $cached.fetch_status = 'stale'
            }
            return $cached
        }
        return $null
    }
    $dir = Split-Path -Parent $CachePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    ($rec | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $CachePath -Encoding utf8NoBOM
    return $rec
}

function Test-QuotaColorEnabled {
    return -not ($env:NO_COLOR -or $env:BATON_NO_COLOR -or ($env:TERM -eq 'dumb'))
}

function Get-QuotaAnsi {
    param([string]$Name)
    if (-not (Test-QuotaColorEnabled)) { return '' }
    switch ($Name) {
        'green'  { return ([char]27 + '[32m') }
        'yellow' { return ([char]27 + '[33m') }
        'red'    { return ([char]27 + '[31m') }
        'dim'    { return ([char]27 + '[90m') }
        'reset'  { return ([char]27 + '[0m') }
        default  { return '' }
    }
}

function Get-QuotaColorName {
    param(
        [double]$Pct,
        $Config = $(Get-CursorQuotaConfig)
    )
    $yellow = [int]$Config.display.yellow_pct
    $red = [int]$Config.display.red_pct
    if ($Pct -ge $red) { return 'red' }
    if ($Pct -ge $yellow) { return 'yellow' }
    return 'green'
}

function Format-QuotaBar {
    param(
        [double]$Pct,
        [int]$Width = 10
    )
    $pctInt = [int][Math]::Round($Pct)
    if ($pctInt -lt 0) { $pctInt = 0 }
    if ($pctInt -gt 100) { $pctInt = 100 }
    if ($Width -lt 1) { $Width = 10 }
    $filled = [int][Math]::Round(($pctInt / 100.0) * $Width)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }
    return (('█' * $filled) + ('░' * ($Width - $filled)))
}

function Format-CursorQuotaDetailTail {
    param(
        $Cache,
        $Config = $(Get-CursorQuotaConfig)
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Cache.days_left) { [void]$parts.Add("$($Cache.days_left)d left") }
    if ([bool]$Config.display.show_auto_api) {
        if ($null -ne $Cache.auto_used_pct) {
            [void]$parts.Add(('auto {0}%' -f [int][Math]::Round([double]$Cache.auto_used_pct)))
        }
        if ($null -ne $Cache.api_used_pct) {
            [void]$parts.Add(('API {0}%' -f [int][Math]::Round([double]$Cache.api_used_pct)))
        }
    }
    if ($parts.Count -eq 0) { return '' }
    return (' · ' + ($parts -join ' · '))
}

function Format-CursorQuotaStatusLine {
    param(
        $Cache,
        [ValidateSet('compact', 'detail', 'ansi')][string]$Format = 'compact',
        $Config = $(Get-CursorQuotaConfig)
    )
    if (-not $Cache -or $null -eq $Cache.total_used_pct) { return $null }
    $pct = [int][Math]::Round([double]$Cache.total_used_pct)
    $barW = [int]$Config.display.bar_width
    $bar = Format-QuotaBar -Pct $pct -Width $barW
    $tail = Format-CursorQuotaDetailTail -Cache $Cache -Config $Config
    $label = 'cursor'
    if ($Format -eq 'detail') {
        return ('{0} cycle  {1}  {2,3}%{3}' -f $label, $bar, $pct, $tail)
    }
    if ($Format -eq 'ansi') {
        $color = Get-QuotaAnsi (Get-QuotaColorName -Pct $pct -Config $Config)
        $reset = Get-QuotaAnsi reset
        if ($Format -eq 'detail') { }
        $compactTail = if ($null -ne $Cache.days_left) { " · $($Cache.days_left)d left" } else { '' }
        return ("{0}{1} {2} {3}%%{4}{5}" -f $color, $label, $bar, $pct, $compactTail, $reset)
    }
    return ('{0} {1} {2}%{3}' -f $label, $bar, $pct, $(if ($null -ne $Cache.days_left) { " · $($Cache.days_left)d left" } else { '' }))
}

function Format-ClaudeQuotaStatusLine {
    param(
        $Cache,
        [ValidateSet('compact', 'detail', 'ansi')][string]$Format = 'detail',
        $Config = $(Get-CursorQuotaConfig)
    )
    if (-not $Cache -or -not $Cache.five_hour -or $null -eq $Cache.five_hour.used_pct) { return $null }
    $pct = [int][Math]::Round([double]$Cache.five_hour.used_pct)
    $barW = [int]$Config.display.bar_width
    $bar = Format-QuotaBar -Pct $pct -Width $barW
    $resetTxt = ''
    if ($Cache.five_hour.resets_at_unix) {
        try {
            $resetDt = [datetimeoffset]::FromUnixTimeSeconds([int64]$Cache.five_hour.resets_at_unix).ToLocalTime()
            $resetTxt = ' resets ' + $resetDt.ToString('h:mm tt')
        } catch { }
    }
    if ($Format -eq 'ansi') {
        $color = Get-QuotaAnsi (Get-QuotaColorName -Pct $pct -Config $Config)
        $reset = Get-QuotaAnsi reset
        return ("{0}5h {1} {2}%%{3}{4}" -f $color, $bar, $pct, $resetTxt, $reset)
    }
    return ('Claude 5h     {0}  {1,3}%{2}' -f $bar, $pct, $resetTxt)
}

function Format-BatonQuotaPanel {
    param(
        [string]$BatonHome = $(Get-BatonHome),
        [switch]$Refresh
    )
    $cfg = Get-CursorQuotaConfig -BatonHome $BatonHome
    $cursor = Update-CursorQuotaCache -BatonHome $BatonHome -Force:$Refresh
    $claude = Read-ClaudeQuotaCache -BatonHome $BatonHome
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('  quotas')
    $cl = Format-ClaudeQuotaStatusLine -Cache $claude -Format detail -Config $cfg
    if ($cl) { $lines.Add('  ' + $cl) } else { $lines.Add('  Claude 5h     — (no snapshot yet — run Claude Code once)') }
    $cu = Format-CursorQuotaStatusLine -Cache $cursor -Format detail -Config $cfg
    if ($cu) {
        $stale = if ([string]$cursor.fetch_status -eq 'stale') { ' (stale)' } else { '' }
        $lines.Add('  ' + $cu + $stale)
    } else {
        $lines.Add('  Cursor cycle  — (unavailable — open Cursor desktop or check sqlite3)')
    }
    $lines.Add(('  {0}tweak display in {1}{2}' -f (Get-QuotaAnsi dim), (Get-CursorQuotaConfigPath -BatonHome $BatonHome), (Get-QuotaAnsi reset)))
    return ($lines -join [Environment]::NewLine)
}

function Resolve-CursorQuotaScript {
    $names = @('cursor-quota.ps1')
    $roots = [System.Collections.Generic.List[string]]::new()
    if ($env:BATON_REPO_ROOT) { $roots.Add((Join-Path $env:BATON_REPO_ROOT 'scripts')) }
    if ($env:BATON_HOME) { $roots.Add((Join-Path $env:BATON_HOME 'scripts')) }
    if ($PSScriptRoot) { $roots.Add($PSScriptRoot) }
    $roots.Add((Join-Path $HOME '.claude/scripts'))
    $roots.Add((Join-Path $HOME 'Dev/Baton/scripts'))
    foreach ($root in $roots) {
        if (-not $root) { continue }
        foreach ($n in $names) {
            $p = Join-Path $root $n
            if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
        }
    }
    return $null
}
