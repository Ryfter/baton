#!/usr/bin/env pwsh
<# SessionStart adapter: stamp a neutral session marker for active detection
   (d076 / #144). Runs on startup|resume|clear|compact. Always exits 0. #>
$ErrorActionPreference = 'Continue'

function Write-SessionMarkerDiag {
    param([string]$Message)
    try {
        $root = if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }
        $logDir = Join-Path $root 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        $logPath = Join-Path $logDir 'session-marker.log'
        $ts = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        Add-Content -LiteralPath $logPath -Value "$ts | $Message" -Encoding utf8NoBOM
    } catch {
        # Last resort: swallow. Never crash the hook.
    }
}

try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $libCandidates = @(
        (Join-Path $scriptDir '../session-markers-lib.ps1'),
        (Join-Path $scriptDir '../scripts/session-markers-lib.ps1')
    )
    $libPath = $libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $libPath) {
        Write-SessionMarkerDiag 'session-markers-lib.ps1 not found; marker not written'
        exit 0
    }
    . $libPath

    $sid = $null
    $cwd = (Get-Location).Path
    $kind = 'startup'
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw) {
                $payload = $raw | ConvertFrom-Json
                if ($payload.session_id) { $sid = [string]$payload.session_id }
                if ($payload.cwd) { $cwd = [string]$payload.cwd }
                # Claude Code SessionStart payload uses source=startup|resume|clear|compact.
                if ($payload.source) {
                    $kind = [string]$payload.source
                } elseif ($payload.hook_event_name) {
                    $kind = [string]$payload.hook_event_name
                }
            }
        }
    } catch { }

    if (-not $sid) {
        Write-SessionMarkerDiag 'session_id absent from SessionStart payload; marker not written'
        exit 0
    }

    $ok = Write-SessionMarker -Agent 'claude' -SessionId $sid -Cwd $cwd -Kind $kind
    if (-not $ok) {
        Write-SessionMarkerDiag "Write-SessionMarker failed for session_id=$sid kind=$kind cwd=$cwd"
    }

    # Window-service briefing (#147): SessionStart stdout is injected into context.
    # Silent when absent, disabled, or on any error — never throw.
    try {
        $wsLibCandidates = @(
            (Join-Path $scriptDir '../window-service-lib.ps1'),
            (Join-Path $scriptDir '../scripts/window-service-lib.ps1')
        )
        $wsLib = $wsLibCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($wsLib) {
            . $wsLib
            $briefing = Get-ProjectBriefing -ProjectDir $cwd
            if ($briefing) { Write-Output $briefing }
        }
    } catch { }

    exit 0
} catch {
    try { Write-SessionMarkerDiag "hook crashed: $($_.Exception.Message)" } catch { }
    exit 0
}
