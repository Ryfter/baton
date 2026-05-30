#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Per-project cost ledger — manual entry of running totals from billing dashboards.

.DESCRIPTION
  Stores at ~/.claude/knowledge/projects/<project-id>/cost.md as a markdown table.
  Reuses Plan 3's Resolve-ProjectId. Each entry: date | total | delta | source | note.
  Header "**Current total: $X** (as of YYYY-MM-DD)" is auto-maintained.
  Cross-project aggregation deferred to Plan 7 multi-project command center.
#>

$script:JobLibPath = Join-Path $PSScriptRoot 'job-lib.ps1'
if (Test-Path $script:JobLibPath) { . $script:JobLibPath }

$script:DefaultKbRoot = (Join-Path $HOME '.claude/knowledge')

function Get-CostPath {
    <# Path to the cost.md for a project (auto-resolves project if not given). #>
    param(
        [string]$Project,
        [string]$KbRoot = $script:DefaultKbRoot
    )
    if (-not $Project) {
        if (Get-Command Resolve-ProjectId -ErrorAction SilentlyContinue) {
            $Project = Resolve-ProjectId
        }
        if (-not $Project) { $Project = '_uncategorized' }
    }
    return (Join-Path $KbRoot "projects/$Project/cost.md")
}

function Read-CostState {
    <# Parse cost.md, return @{ current; lastDate; entries = @(@{date;total;delta;source;note}) }. #>
    param([Parameter(Mandatory)][string]$Path)
    $result = @{ current = [decimal]0; lastDate = $null; entries = @() }
    if (-not (Test-Path $Path)) { return $result }
    foreach ($line in (Get-Content $Path)) {
        # Match table data rows: | YYYY-MM-DD | $total | +/-$delta | source | note |
        if ($line -match '^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*\$([\d.]+)\s*\|\s*([+-]?\$?[\d.]+)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|') {
            $entry = @{
                date   = $matches[1]
                total  = [decimal]$matches[2]
                delta  = $matches[3]
                source = $matches[4]
                note   = $matches[5]
            }
            $result.entries += $entry
            $result.current  = $entry.total
            $result.lastDate = $entry.date
        }
    }
    return $result
}

function Add-CostEntry {
    <# Append a new row, recompute delta from previous total, refresh the Current-total header. #>
    param(
        [Parameter(Mandatory)][decimal]$Total,
        [string]$Source = 'Claude Code billing',
        [string]$Note = '',
        [string]$Project,
        [string]$KbRoot = $script:DefaultKbRoot
    )
    $path = Get-CostPath -Project $Project -KbRoot $KbRoot
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $state = Read-CostState -Path $path
    $delta = $Total - $state.current
    $deltaStr = if ($delta -ge 0) { ('+$' + ('{0:F2}' -f $delta)) } else { ('-$' + ('{0:F2}' -f [Math]::Abs($delta))) }
    $totalStr = '$' + ('{0:F2}' -f $Total)
    $today = Get-Date -Format 'yyyy-MM-dd'
    $safeSource = ($Source -replace '\|', '¦').Trim()
    $safeNote   = ($Note   -replace '\|', '¦' -replace "`r?`n", ' ').Trim()

    $projName = if ($Project) { $Project } elseif (Get-Command Resolve-ProjectId -ErrorAction SilentlyContinue) { Resolve-ProjectId } else { '_uncategorized' }

    if ($state.entries.Count -eq 0) {
        $content = @"
# Cost — $projName

**Current total: $totalStr** (as of $today)

## History

| Date       | Total    | Delta     | Source              | Note |
|------------|----------|-----------|---------------------|------|
| $today | $totalStr | $deltaStr | $safeSource | $safeNote |
"@
        Set-Content -Path $path -Value $content -Encoding utf8NoBOM
    } else {
        $newRow = "| $today | $totalStr | $deltaStr | $safeSource | $safeNote |"
        Add-Content -Path $path -Value $newRow -Encoding utf8NoBOM
        # Update header line in-place
        $lines = Get-Content $path
        $updated = $lines | ForEach-Object {
            if ($_ -match '^\*\*Current total:') {
                "**Current total: $totalStr** (as of $today)"
            } else { $_ }
        }
        Set-Content -Path $path -Value ($updated -join "`n") -Encoding utf8NoBOM
    }
    return @{ total = $Total; delta = $delta; path = $path }
}
