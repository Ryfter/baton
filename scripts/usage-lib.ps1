#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Usage Governor (Sprint 2). Worker-availability state machine seeded by v1's
  usage_class: an append-only usage-journal.jsonl folded to current state, a global
  conserve posture, and a best-effort usage forecast.
.DESCRIPTION
  Availability/recommendation only — does not dispatch work or meter billing.
  See docs/superpowers/specs/2026-06-16-usage-governor-sprint2-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # Read-Fleet for Get-WorkerBudget / Get-AllWorkerStates

$script:DefaultUsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl')

function Read-UsageJournal {
    <# Robust JSONL reader: missing path -> empty; malformed lines skipped. object[]. #>
    param([string]$Path = $script:DefaultUsagePath)
    if (-not $Path -or -not (Test-Path $Path)) { return ([object[]]@()) }
    $out = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return ([object[]]$out.ToArray())
}

function Add-UsageEvent {
    <# Append one event row. -Kind is the event type (field name is `event`).
       Never throws on write fault — warns. Creates the parent dir. #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Worker,
        [hashtable]$Fields = @{},
        [string]$Path = $script:DefaultUsagePath,
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
    $row = [ordered]@{ ts = $Timestamp; event = $Kind; worker = $Worker }
    foreach ($k in $Fields.Keys) { $row[$k] = $Fields[$k] }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $Path -Value ($row | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8
    } catch {
        Write-Warning "usage: failed to append event to $Path : $($_.Exception.Message)"
    }
}

function ConvertTo-UsageInstant {
    <# Parse a relative shorthand (+90m,+5h,+2d) or ISO-8601 into a UTC ISO-8601 string. #>
    param([Parameter(Mandatory)][string]$When, [datetime]$Now = [datetime]::UtcNow)
    $w = $When.Trim()
    if ($w -match '^\+(\d+)([smhd])$') {
        $n = [int]$matches[1]
        $span = switch ($matches[2]) {
            's' { [timespan]::FromSeconds($n) }
            'm' { [timespan]::FromMinutes($n) }
            'h' { [timespan]::FromHours($n) }
            'd' { [timespan]::FromDays($n) }
        }
        return ($Now.ToUniversalTime() + $span).ToString('o')
    }
    $dto = [datetimeoffset]::Parse($w, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
    return $dto.UtcDateTime.ToString('o')
}

function ConvertTo-UsageDateTime {
    <# Parse an ISO-8601 string to a UTC DateTime; junk -> DateTime.MinValue. #>
    param([string]$Ts)
    if (-not $Ts) { return [datetime]::MinValue }
    try { return ([datetimeoffset]::Parse($Ts, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).UtcDateTime }
    catch { return [datetime]::MinValue }
}
