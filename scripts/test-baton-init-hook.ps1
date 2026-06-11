#!/usr/bin/env pwsh
# Tests for the SessionStart baton-init hook: seeds configs + runs migration,
# idempotent, never exits non-zero. Fully isolated via BATON_HOME/BATON_CLAUDE_DIR.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hook = Join-Path $here 'hooks/baton-init.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME; $savedClaude = $env:BATON_CLAUDE_DIR
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "baton-init-test-$([guid]::NewGuid().ToString('N'))"
try {
    $env:BATON_HOME = Join-Path $tmp 'baton'
    $env:BATON_CLAUDE_DIR = Join-Path $tmp 'claude'
    New-Item -ItemType Directory -Force -Path $env:BATON_CLAUDE_DIR | Out-Null
    Set-Content (Join-Path $env:BATON_CLAUDE_DIR 'current-job.json') '{"job_id":"legacy"}' -Encoding utf8NoBOM

    & pwsh -NoProfile -File $hook | Out-Null
    Assert "hook exits 0"                     ($LASTEXITCODE -eq 0)
    Assert "seeds fleet.yaml from references" (Test-Path (Join-Path $env:BATON_HOME 'fleet.yaml'))
    Assert "seeds tools.yaml"                 (Test-Path (Join-Path $env:BATON_HOME 'tools.yaml'))
    Assert "seeds prime-hours.yaml"           (Test-Path (Join-Path $env:BATON_HOME 'prime-hours.yaml'))
    Assert "migrates legacy current-job"      (Test-Path (Join-Path $env:BATON_HOME 'current-job.json'))
    Assert "writes migration marker"          (Test-Path (Join-Path $env:BATON_HOME '.migrated-from-claude.json'))

    Set-Content (Join-Path $env:BATON_HOME 'fleet.yaml') 'user: edited' -Encoding utf8NoBOM
    & pwsh -NoProfile -File $hook | Out-Null
    Assert "second run exits 0"               ($LASTEXITCODE -eq 0)
    Assert "second run keeps user config"     ((Get-Content (Join-Path $env:BATON_HOME 'fleet.yaml') -Raw).Trim() -eq 'user: edited')
} finally {
    $env:BATON_HOME = $savedHome; $env:BATON_CLAUDE_DIR = $savedClaude
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($failures -gt 0) { exit 1 } else { exit 0 }
