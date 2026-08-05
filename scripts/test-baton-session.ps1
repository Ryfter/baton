#!/usr/bin/env pwsh
# Portable controller lifecycle smoke: Codex/Grok/other shells use the same
# session-marker and resume contract as Claude without relying on Claude hooks.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$baton = Join-Path (Split-Path -Parent $here) 'baton.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "baton-session-$([guid]::NewGuid())"
$batonHome = Join-Path $tmp 'home'
$project = Join-Path $tmp 'project'
New-Item -ItemType Directory -Force -Path $home, $project | Out-Null
$oldHome = $env:BATON_HOME
$env:BATON_HOME = $batonHome
$fail = 0
function Check($name, $condition) {
    if ($condition) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name"; $script:fail++ }
}
try {
    Set-Content -LiteralPath (Join-Path $project 'CHARTER.md') -Value '# Portable session test' -Encoding utf8NoBOM
    $startRaw = & pwsh -NoProfile -File $baton session start --agent codex --session-id codex-session-1 --cwd $project
    $start = ($startRaw -join "`n") | ConvertFrom-Json
    $marker = Join-Path $batonHome 'sessions/codex-session-1.json'
    Check 'S1 session start returns JSON' ($start.ok -eq $true -and $start.agent -eq 'codex')
    Check 'S2 session start writes neutral marker' (Test-Path -LiteralPath $marker)

    $refreshRaw = & pwsh -NoProfile -File $baton session refresh --agent codex --session-id codex-session-1 --cwd $project
    $refresh = ($refreshRaw -join "`n") | ConvertFrom-Json
    Check 'S3 session refresh is available to long-lived controllers' ($refresh.ok -eq $true -and $refresh.action -eq 'refresh')

    $stopRaw = & pwsh -NoProfile -File $baton session stop --agent codex --session-id codex-session-1 --cwd $project
    $stop = ($stopRaw -join "`n") | ConvertFrom-Json
    Check 'S4 session stop returns JSON' ($stop.ok -eq $true -and $stop.action -eq 'stop')
    Check 'S5 session stop clears marker' (-not (Test-Path -LiteralPath $marker))
    $records = @(Get-ChildItem -LiteralPath (Join-Path $batonHome 'projects') -Filter 'project.json' -Recurse -ErrorAction SilentlyContinue)
    $record = if ($records.Count -gt 0) { Get-Content -Raw -LiteralPath $records[0].FullName | ConvertFrom-Json }
    Check 'S6 session stop writes generic-agent resume pointer' ($record.agent -eq 'codex' -and $record.last_session_id -eq 'codex-session-1')
} finally {
    if ($oldHome) { $env:BATON_HOME = $oldHome } else { Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail -gt 0) { exit 1 }
Write-Host 'ALL CHECKS PASS'
