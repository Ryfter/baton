#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Single resolver for Baton's state root (BATON_HOME) + first-run seeding and the
  one-time ~/.claude -> BATON_HOME state migration. Dot-source from libs and hooks.
.DESCRIPTION
  State (jobs, runs, journals, config yamls, ideas, ensembles) lives under
  BATON_HOME (default ~/.baton). Deliberately NOT ${CLAUDE_PLUGIN_DATA}: that path
  is Claude-only and id-mangled — Baton state must stay directly readable by
  Codex/Gemini and the Phase-3 MCP server (model-agnostic north star).
  The knowledge base stays at ~/.claude/knowledge (cross-project, repo-backed) —
  it is NOT Baton state and is never migrated.
#>

function Get-BatonHome {
    if ($env:BATON_HOME) { return $env:BATON_HOME }
    return (Join-Path $HOME '.baton')
}

function Initialize-BatonHome {
    <# Create the BATON_HOME skeleton + seed config yamls from a references dir.
       Idempotent: never overwrites an existing config. Returns seeded file names. #>
    param([Parameter(Mandatory)][string]$ReferencesDir)
    $root = Get-BatonHome
    foreach ($d in @($root, (Join-Path $root 'jobs'), (Join-Path $root 'runs'), (Join-Path $root 'logs'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    $seeded = [System.Collections.ArrayList]@()
    foreach ($cfg in @('fleet.yaml', 'tools.yaml', 'prime-hours.yaml', 'verify-presets.json', 'review-roles.yaml')) {
        $src = Join-Path $ReferencesDir $cfg
        $dst = Join-Path $root $cfg
        if ((Test-Path $src) -and -not (Test-Path $dst)) {
            Copy-Item $src $dst
            [void]$seeded.Add($cfg)
        }
    }
    return $seeded.ToArray()
}

function Move-BatonState {
    <# One-time migration of mutable state from ~/.claude into BATON_HOME.
       Marker-gated and idempotent. Never clobbers: if source AND destination
       exist, the source stays put and is reported as a conflict.
       Returns @{ migrated; skipped; conflicts }. #>
    param(
        [string]$ClaudeDir = $(if ($env:BATON_CLAUDE_DIR) { $env:BATON_CLAUDE_DIR } else { Join-Path $HOME '.claude' }),
        [string]$BatonHome = (Get-BatonHome)
    )
    $marker = Join-Path $BatonHome '.migrated-from-claude.json'
    $result = @{ migrated = @(); skipped = @(); conflicts = @() }
    if (Test-Path $marker) { $result.skipped = @('(marker present — already migrated)'); return $result }
    if (-not (Test-Path $BatonHome)) { New-Item -ItemType Directory -Force -Path $BatonHome | Out-Null }
    $items = @(
        'jobs', 'runs', 'ideas', 'ensembles',
        'current-job.json', 'routing-journal.jsonl', 'model-routing-log.md',
        'fleet.yaml', 'tools.yaml', 'prime-hours.yaml'
    )
    foreach ($name in $items) {
        $src = Join-Path $ClaudeDir $name
        $dst = Join-Path $BatonHome $name
        if (-not (Test-Path $src)) { $result.skipped += $name; continue }
        if (Test-Path $dst) { $result.conflicts += $name; continue }
        Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
        $result.migrated += $name
    }
    @{
        at        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        from      = $ClaudeDir
        migrated  = $result.migrated
        conflicts = $result.conflicts
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $marker -Encoding utf8NoBOM
    return $result
}
