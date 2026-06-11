#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Time-awareness gate + capacity profile (Cost-Optimization Engine, Slice A). Gates
  paid/frontier dispatch by item rank during prime-peak windows; reports a concurrency
  surge during off-peak/weekend windows. PURE: returns decisions, never prompts.
.DESCRIPTION
  Reads ~/.claude/prime-hours.yaml. -Now is injectable so tests are clock-independent.
  Fail-open: a missing/garbage config never blocks work (returns allow). The gate guards
  ONLY the paid tier inside a peak window — local/free and off-peak always allow. Ranks
  0 and 6 are RESERVED rows in the policy table (one-line future activation), intentionally
  undocumented in v1. See docs/superpowers/specs/2026-06-10-cost-optimization-engine-design.md.
#>

. "$PSScriptRoot/fleet-lib.ps1"   # ConvertFrom-FleetValue

$script:DefaultPrimeHoursPath = (Join-Path $HOME '.claude/prime-hours.yaml')

function Read-PrimeHoursConfig {
    <# Parse prime-hours.yaml -> @{ timezone; default_rank; windows=@(@{name;days;start;end;kind;concurrency_factor}) }.
       Fail-open: missing/garbage -> permissive default (no windows). #>
    param([string]$Path = $script:DefaultPrimeHoursPath)
    $default = @{ timezone='local'; default_rank=3; windows=@() }
    if (-not $Path -or -not (Test-Path $Path)) { return $default }
    try {
        $cfg = @{ timezone='local'; default_rank=3; windows=[System.Collections.ArrayList]@() }
        $cur = $null; $inWindows = $false
        foreach ($raw in (Get-Content -LiteralPath $Path)) {
            if ($raw -match '^\s*#') { continue }
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            if ($raw -match '^timezone:\s*(.+?)\s*$')    { $cfg.timezone = [string](ConvertFrom-FleetValue $matches[1]); continue }
            if ($raw -match '^default_rank:\s*(.+?)\s*$') { $cfg.default_rank = [int](ConvertFrom-FleetValue $matches[1]); continue }
            if ($raw -match '^windows:\s*$') { $inWindows = $true; continue }
            if (-not $inWindows) { continue }
            if ($raw -match '^\s*-\s+name:\s*(.+?)\s*$') {
                if ($cur) { [void]$cfg.windows.Add($cur) }
                $cur = @{ name=[string](ConvertFrom-FleetValue $matches[1]); days=@(); start=$null; end=$null; kind='peak'; concurrency_factor=2.0 }
                continue
            }
            if (-not $cur) { continue }
            if ($raw -match '^\s+days:\s*\[(.*?)\]\s*$') {
                $cur.days = @($matches[1] -split ',' | ForEach-Object { ([string](ConvertFrom-FleetValue $_)).Trim() } | Where-Object { $_ })
                continue
            }
            if ($raw -match '^\s+([\w.-]+):\s*(.+?)\s*$') {
                $k = $matches[1]; $v = ConvertFrom-FleetValue $matches[2]
                if ($k -eq 'concurrency_factor') { $cur[$k] = [double]$v } else { $cur[$k] = [string]$v }
            }
        }
        if ($cur) { [void]$cfg.windows.Add($cur) }
        $cfg.windows = $cfg.windows.ToArray()
        return $cfg
    } catch {
        Write-Warning "prime-hours config parse failed ($($_.Exception.Message)); failing open."
        return $default
    }
}

function Get-PrimeHoursNow {
    <# Current wall-clock in the configured tz. 'local'/unknown -> machine-local. #>
    param([string]$Timezone)
    if (-not $Timezone -or $Timezone -eq 'local') { return (Get-Date) }
    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
        return [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
    } catch {
        Write-Warning "prime-hours timezone '$Timezone' not found; using machine-local."
        return (Get-Date)
    }
}

function Test-InWindow {
    <# Is $Now inside $Window? Day-of-week match (3-letter, case-insensitive) AND, if the
       window has start/end, the time in [start, end). A window with no start/end = all day. #>
    param([Parameter(Mandatory)][hashtable]$Window, [Parameter(Mandatory)][datetime]$Now)
    $days = @($Window.days | ForEach-Object { "$_".Trim().ToLower() } | Where-Object { $_ } | ForEach-Object { $_.Substring(0,[Math]::Min(3,$_.Length)) })
    if ($days.Count -gt 0) {
        $dow3 = $Now.DayOfWeek.ToString().Substring(0,3).ToLower()
        if ($days -notcontains $dow3) { return $false }
    }
    if ($Window.start -and $Window.end) {
        $toMin = { param($s) $p = "$s" -split ':'; [int]$p[0]*60 + [int]$p[1] }
        $nowM = (& $toMin ($Now.ToString('HH:mm'))); $sM = (& $toMin $Window.start); $eM = (& $toMin $Window.end)
        if ($nowM -lt $sM -or $nowM -ge $eM) { return $false }
    }
    return $true
}

function Get-PrimeRankPolicy {
    <# Rank -> peak-window policy for a PAID dispatch. #1 highest .. #5 lowest. Ranks 0 and 6
       are RESERVED (rows present so future activation is one line) and undocumented in v1.
       Unknown rank -> DefaultRank's policy. #>
    param([int]$Rank, [int]$DefaultRank = 3)
    $table = @{
        0 = @{ decision='allow'; default='run'   }   # reserved: emergency / preempt (undocumented)
        1 = @{ decision='ask';   default='run'   }
        2 = @{ decision='ask';   default='defer' }
        3 = @{ decision='defer'; default='defer' }
        4 = @{ decision='defer'; default='defer' }
        5 = @{ decision='defer'; default='defer' }
        6 = @{ decision='defer'; default='defer' }   # reserved: frugal/local-only/surge-only (undocumented; full semantics deferred)
    }
    if ($table.ContainsKey($Rank)) { return $table[$Rank] }
    if ($table.ContainsKey($DefaultRank)) { return $table[$DefaultRank] }
    return @{ decision='defer'; default='defer' }
}

function Test-PrimeHoursGate {
    <# Decide whether a dispatch may proceed now. Returns
       @{ decision='allow'|'ask'|'defer'; default='run'|'defer'; reason; window }.
       local/free -> allow. paid off-peak -> allow. paid in a peak window -> rank policy. #>
    param(
        [int]$Rank = [int]::MinValue,
        [Parameter(Mandatory)][ValidateSet('local','free','paid')][string]$CostTier,
        [datetime]$Now,
        [string]$ConfigPath = $script:DefaultPrimeHoursPath
    )
    $cfg = Read-PrimeHoursConfig -Path $ConfigPath
    if ($Rank -eq [int]::MinValue) { $Rank = [int]$cfg.default_rank }
    if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = Get-PrimeHoursNow -Timezone $cfg.timezone }

    if ($CostTier -ne 'paid') {
        return @{ decision='allow'; default='run'; reason="$CostTier tier is free"; window=$null }
    }
    $peak = $null
    foreach ($w in @($cfg.windows)) {
        if ([string]$w.kind -eq 'peak' -and (Test-InWindow -Window $w -Now $Now)) { $peak = $w; break }
    }
    if (-not $peak) {
        return @{ decision='allow'; default='run'; reason='paid, off-peak'; window=$null }
    }
    $p = Get-PrimeRankPolicy -Rank $Rank -DefaultRank ([int]$cfg.default_rank)
    return @{ decision=$p.decision; default=$p.default; reason="paid in peak window '$($peak.name)' (rank $Rank)"; window=[string]$peak.name }
}

function Get-CapacityProfile {
    <# Per-session concurrency profile. In a 'surge' window -> that window's concurrency_factor
       (default 2) + surge=$true; otherwise baseline 1 / surge=$false. Drives max-parallel
       subagent count + deferred-queue drain in the backlog/run-loop. #>
    param([datetime]$Now, [string]$ConfigPath = $script:DefaultPrimeHoursPath)
    $cfg = Read-PrimeHoursConfig -Path $ConfigPath
    if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = Get-PrimeHoursNow -Timezone $cfg.timezone }
    foreach ($w in @($cfg.windows)) {
        if ([string]$w.kind -eq 'surge' -and (Test-InWindow -Window $w -Now $Now)) {
            $cf = if ($w.concurrency_factor) { [double]$w.concurrency_factor } else { 2.0 }
            return @{ concurrency_factor=$cf; surge=$true; window=[string]$w.name }
        }
    }
    return @{ concurrency_factor=1.0; surge=$false; window=$null }
}
