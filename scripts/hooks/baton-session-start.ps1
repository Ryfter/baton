#!/usr/bin/env pwsh
<# SessionStart(startup) adapter: stamp a neutral session marker for active
   detection (d076). Non-blocking: always exits 0. #>
$ErrorActionPreference = 'Continue'
try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $libCandidates = @(
        (Join-Path $scriptDir '../session-markers-lib.ps1'),
        (Join-Path $scriptDir '../scripts/session-markers-lib.ps1')
    )
    $libPath = $libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $libPath) { exit 0 }
    . $libPath

    $sid = $null; $cwd = (Get-Location).Path
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw) {
                $payload = $raw | ConvertFrom-Json
                if ($payload.session_id) { $sid = [string]$payload.session_id }
                if ($payload.cwd) { $cwd = [string]$payload.cwd }
            }
        }
    } catch { }
    if ($sid) { Write-SessionMarker -Agent 'claude' -SessionId $sid -Cwd $cwd }
    exit 0
} catch { exit 0 }
