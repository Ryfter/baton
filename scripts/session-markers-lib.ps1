#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Neutral session-marker contract for active-project detection (d076).
  Any agent harness writes the same marker shape; the registry reads it.
  Fail-open: a broken store degrades to "no active sessions", never throws.
#>
. "$PSScriptRoot/baton-home.ps1"

function Get-SessionsDir {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'sessions')
}

function Write-SessionMarker {
    param(
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Cwd,
        [string]$Kind = 'startup',
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $dir = Get-SessionsDir -BatonHome $BatonHome
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $safe = ($SessionId -replace '[^A-Za-z0-9._-]+', '_')
        $path = Join-Path $dir "$safe.json"
        $now = (Get-Date).ToUniversalTime().ToString('o')
        # Re-stamp must keep the original start time — resume/compact is not a new session.
        $startedAt = $now
        if (Test-Path -LiteralPath $path) {
            try {
                $existing = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($existing.started_at) {
                    $startedAt = ([datetime]$existing.started_at).ToUniversalTime().ToString('o')
                }
            } catch { }
        }
        $rec = [ordered]@{
            agent        = $Agent
            session_id   = $SessionId
            cwd          = $Cwd
            started_at   = $startedAt
            last_seen_at = $now
            kind         = $Kind
        }
        ConvertTo-Json -InputObject $rec -Depth 4 |
            Set-Content -LiteralPath $path -Encoding utf8NoBOM
        return $true
    } catch {
        Write-Debug "Write-SessionMarker: $($_.Exception.Message)"
        return $false
    }
}

function Update-SessionMarkerLastSeen {
    <# Throttled re-stamp for long-running sessions (issue #144).
       Returns $true if a write happened, $false if skipped/failed. Never throws. #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Agent,
        [string]$Cwd,
        [string]$Kind = 'refresh',
        [int]$MinIntervalMinutes = 5,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $safe = ($SessionId -replace '[^A-Za-z0-9._-]+', '_')
        $path = Join-Path (Get-SessionsDir -BatonHome $BatonHome) "$safe.json"
        if (-not (Test-Path -LiteralPath $path)) { return $false }

        $existing = $null
        try {
            $existing = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return $false
        }
        if (-not $existing) { return $false }

        # Prefer last_seen_at; fall back to started_at for pre-#144 markers.
        $ageRaw = $null
        if ($existing.PSObject.Properties.Name -contains 'last_seen_at' -and $existing.last_seen_at) {
            $ageRaw = $existing.last_seen_at
        } elseif ($existing.started_at) {
            $ageRaw = $existing.started_at
        }
        if ($ageRaw) {
            $last = ([datetime]$ageRaw).ToUniversalTime()
            $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-1 * [math]::Abs($MinIntervalMinutes))
            if ($last -ge $cutoff) { return $false }
        }

        $agentVal = if ($Agent) { $Agent } elseif ($existing.agent) { [string]$existing.agent } else { 'claude' }
        $cwdVal = if ($Cwd) { $Cwd } elseif ($existing.cwd) { [string]$existing.cwd } else { (Get-Location).Path }
        return [bool](Write-SessionMarker -Agent $agentVal -SessionId $SessionId -Cwd $cwdVal -Kind $Kind -BatonHome $BatonHome)
    } catch {
        Write-Debug "Update-SessionMarkerLastSeen: $($_.Exception.Message)"
        return $false
    }
}

function Clear-SessionMarker {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $safe = ($SessionId -replace '[^A-Za-z0-9._-]+', '_')
        $path = Join-Path (Get-SessionsDir -BatonHome $BatonHome) "$safe.json"
        if (-not (Test-Path $path)) { return $null }
        $rec = $null
        try { $rec = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $rec
    } catch { Write-Debug "Clear-SessionMarker: $($_.Exception.Message)"; return $null }
}

function Get-ActiveSessions {
    param(
        [int]$TtlHours = 24,
        [string]$BatonHome = (Get-BatonHome)
    )
    $out = [System.Collections.ArrayList]@()
    try {
        $dir = Get-SessionsDir -BatonHome $BatonHome
        if (-not (Test-Path $dir)) { return @() }
        $cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * [math]::Abs($TtlHours))
        foreach ($f in Get-ChildItem -File -Path $dir -Filter '*.json' -ErrorAction SilentlyContinue) {
            try {
                $rec = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                # Age out on last_seen_at when present; fall back to started_at for legacy markers.
                $ageRaw = $null
                if ($rec.PSObject.Properties.Name -contains 'last_seen_at' -and $rec.last_seen_at) {
                    $ageRaw = $rec.last_seen_at
                } elseif ($rec.started_at) {
                    $ageRaw = $rec.started_at
                }
                if (-not $ageRaw) { continue }
                $seen = ([datetime]$ageRaw).ToUniversalTime()
                if ($seen -ge $cutoff) { [void]$out.Add($rec) }
            } catch { }
        }
    } catch { Write-Debug "Get-ActiveSessions: $($_.Exception.Message)" }
    if ($out.Count -eq 0) { return @() }
    return ,([object[]]$out.ToArray())
}

function Test-FolderActive {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [object[]]$Sessions = @()
    )
    try {
        $target = [IO.Path]::GetFullPath($Folder).TrimEnd('\','/')
        foreach ($s in $Sessions) {
            if (-not $s.cwd) { continue }
            $c = [IO.Path]::GetFullPath([string]$s.cwd).TrimEnd('\','/')
            if ($c -ieq $target) { return $true }
        }
    } catch { }
    return $false
}
