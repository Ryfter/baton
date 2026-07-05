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
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $dir = Get-SessionsDir -BatonHome $BatonHome
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $safe = ($SessionId -replace '[^A-Za-z0-9._-]+', '_')
        $rec = [ordered]@{
            agent      = $Agent
            session_id = $SessionId
            cwd        = $Cwd
            started_at = (Get-Date).ToUniversalTime().ToString('o')
        }
        ConvertTo-Json -InputObject $rec -Depth 4 |
            Set-Content -LiteralPath (Join-Path $dir "$safe.json") -Encoding utf8NoBOM
    } catch { Write-Debug "Write-SessionMarker: $($_.Exception.Message)" }
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
                if (-not $rec.started_at) { continue }
                # ConvertFrom-Json already parsed started_at to [datetime]; normalize to UTC.
                $started = ([datetime]$rec.started_at).ToUniversalTime()
                if ($started -ge $cutoff) { [void]$out.Add($rec) }
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
