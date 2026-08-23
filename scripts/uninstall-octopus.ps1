#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Remove Claude Octopus from the box after Baton unification.
#>
param([switch]$DryRun, [switch]$Force)

$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "    ok: $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    warn: $m" -ForegroundColor Yellow }

Step 'Checking for octo@nyldn-plugins'
$list = & claude plugin list 2>&1 | Out-String
if ($list -notmatch 'octo@nyldn-plugins') {
    Ok 'Octopus not installed — nothing to remove'
} else {
    if ($DryRun) {
        Warn '[dry-run] would run: claude plugin uninstall octo@nyldn-plugins'
    } else {
        & claude plugin uninstall octo@nyldn-plugins
        if ($LASTEXITCODE -ne 0) { throw "uninstall failed ($LASTEXITCODE)" }
        Ok 'uninstalled octo@nyldn-plugins'
    }
}

$octoHome = Join-Path $HOME '.claude-octopus'
if (Test-Path -LiteralPath $octoHome) {
    if ($DryRun) {
        Warn "[dry-run] would remove $octoHome (use -Force)"
    } elseif ($Force) {
        Remove-Item -LiteralPath $octoHome -Recurse -Force
        Ok "removed $octoHome"
    } else {
        Warn "$octoHome still present — re-run with -Force to delete cached results/logs"
    }
}

Step 'Next'
Write-Host '  pwsh -NoProfile -File scripts/bootstrap.ps1 -Force -NonInteractive'
Write-Host '  See docs/octo-to-baton-map.md for /octo:* replacements'
