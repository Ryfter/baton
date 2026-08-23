#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Refresh and print Cursor billing-cycle usage (cached under BATON_HOME).

.EXAMPLE
  pwsh -NoProfile -File scripts/cursor-quota.ps1 refresh
  pwsh -NoProfile -File scripts/cursor-quota.ps1 panel
  pwsh -NoProfile -File scripts/cursor-quota.ps1 status -Format ansi
#>
param(
    [Parameter(Position = 0)][ValidateSet('refresh', 'status', 'show', 'panel')][string]$Subcommand = 'panel',
    [ValidateSet('compact', 'detail', 'ansi')][string]$Format = '',
    [int]$MaxAgeSeconds = 0,
    [switch]$Json,
    [switch]$Quiet,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cursor-quota-lib.ps1')

$cfg = Get-CursorQuotaConfig
$ttl = if ($MaxAgeSeconds -gt 0) { $MaxAgeSeconds } else { [int]$cfg.cache_ttl_seconds }

switch ($Subcommand) {
    'panel' {
        if ($Json) {
            $cursor = Update-CursorQuotaCache -MaxAgeSeconds $ttl -Force:$Force
            $claude = Read-ClaudeQuotaCache
            [ordered]@{
                claude = $claude
                cursor = $cursor
                config = $cfg
            } | ConvertTo-Json -Depth 6
            exit 0
        }
        Write-Output (Format-BatonQuotaPanel -Refresh:$Force)
        exit 0
    }
    'refresh' {
        $rec = Update-CursorQuotaCache -MaxAgeSeconds $ttl -Force:$true
    }
    default {
        $rec = Update-CursorQuotaCache -MaxAgeSeconds $ttl -Force:$Force
    }
}

if ($Json) {
    if ($rec) { $rec | ConvertTo-Json -Depth 4 } else { '{}' }
    exit 0
}

$fmt = if ($Format) { $Format } else {
    if ($Subcommand -eq 'status') { [string]$cfg.display.statusline_format } else { 'compact' }
}
$line = Format-CursorQuotaStatusLine -Cache $rec -Format $fmt -Config $cfg
if ($Quiet) { exit $(if ($line) { 0 } else { 1 }) }
if ($line) { Write-Output $line } else { Write-Output 'cursor — (unavailable)' }
exit 0
