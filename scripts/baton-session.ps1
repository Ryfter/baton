#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Portable controller lifecycle adapter for Codex, Grok, and other shells.
  Writes the neutral session-marker contract and preserves the project resume
  pointer without requiring Claude Code hooks.
#>
param(
    [Parameter(Position=0)][ValidateSet('start','refresh','stop')][string]$Action = 'start',
    [string]$Agent = $(if ($env:BATON_AGENT) { $env:BATON_AGENT } else { 'other' }),
    [string]$SessionId = $(if ($env:BATON_SESSION_ID) { $env:BATON_SESSION_ID } else { '' }),
    [string]$Cwd = (Get-Location).Path,
    [string]$Kind = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'session-markers-lib.ps1')
. (Join-Path $PSScriptRoot 'registry-lib.ps1')

function Write-SessionResult {
    param([hashtable]$Result)
    $Result.ok = [bool]$Result.ok
    Write-Output ($Result | ConvertTo-Json -Depth 8 -Compress)
}

try {
    if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = (Get-Location).Path }
    $Cwd = [IO.Path]::GetFullPath($Cwd)
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        if ($Action -eq 'start') { $SessionId = "baton-$([guid]::NewGuid())" }
        else { throw "-SessionId is required for $Action" }
    }
    if ([string]::IsNullOrWhiteSpace($Kind)) { $Kind = $Action }
    $batonHome = Get-BatonHome

    if ($Action -eq 'start') {
        $ok = Write-SessionMarker -Agent $Agent -SessionId $SessionId -Cwd $Cwd -Kind $Kind -BatonHome $batonHome
        Write-SessionResult @{ ok = $ok; action = 'start'; agent = $Agent; session_id = $SessionId; cwd = $Cwd }
        exit $(if ($ok) { 0 } else { 1 })
    }
    if ($Action -eq 'refresh') {
        $updated = Update-SessionMarkerLastSeen -Agent $Agent -SessionId $SessionId -Cwd $Cwd -Kind $Kind -BatonHome $batonHome
        # A throttled refresh is still a successful lifecycle call.
        Write-SessionResult @{ ok = $true; action = 'refresh'; updated = $updated; agent = $Agent; session_id = $SessionId; cwd = $Cwd }
        exit 0
    }

    $cleared = Clear-SessionMarker -SessionId $SessionId -BatonHome $batonHome
    $recorded = $false
    if (Test-IsProjectFolder -Folder $Cwd) {
        $projectsRoot = Join-Path $batonHome 'projects'
        $projectId = Get-ProjectId -Folder $Cwd
        $existing = Read-ProjectRecord -ProjectId $projectId -ProjectsRoot $projectsRoot
        $record = @{}
        if ($existing) { foreach ($p in $existing.PSObject.Properties) { $record[$p.Name] = $p.Value } }
        $record['id'] = $projectId
        if (-not $record.ContainsKey('name')) { $record['name'] = Split-Path -Leaf $Cwd }
        if (-not $record.ContainsKey('folder')) { $record['folder'] = $Cwd }
        $record['agent'] = if ($cleared -and $cleared.agent) { [string]$cleared.agent } else { $Agent }
        $record['last_session_id'] = $SessionId
        $record['last_ended_at'] = (Get-Date).ToUniversalTime().ToString('o')
        Write-ProjectRecord -Record $record -ProjectsRoot $projectsRoot
        $recorded = $true
    }
    Write-SessionResult @{ ok = $true; action = 'stop'; agent = $Agent; session_id = $SessionId; cwd = $Cwd; marker_found = ($null -ne $cleared); resume_recorded = $recorded }
    exit 0
} catch {
    [Console]::Error.WriteLine("baton session: $($_.Exception.Message)")
    exit 2
}
