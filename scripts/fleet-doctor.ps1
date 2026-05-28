#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Health-check the fleet. Probes each enabled provider's reachability.
  Exit 0 if all enabled providers are ok; 1 if any warn/err.
#>
param(
    [string]$Path = (Join-Path $HOME '.claude/fleet.yaml')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

try {
    $fleet = Read-Fleet -Path $Path
} catch {
    Write-Host "fleet doctor: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$rows = @()
$anyBad = $false

foreach ($p in $fleet) {
    $status = 'ok'; $detail = ''
    if ($p.enabled -ne $true) {
        $status = 'skip'; $detail = 'disabled in fleet.yaml'
    }
    elseif ($p.kind -eq 'cli') {
        # First token of the command_template is the binary.
        $bin = ($p.command_template -split '\s+')[0]
        if (Get-Command $bin -ErrorAction SilentlyContinue) {
            $detail = "$bin on PATH"
            # Remote-host check for providers with an OLLAMA_HOST-style env URL.
            if ($p.env) {
                foreach ($k in $p.env.Keys) {
                    $val = $p.env[$k]
                    if ($val -match '^https?://') {
                        try {
                            Invoke-WebRequest -Uri $val -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
                            $detail += "; $k reachable"
                        } catch {
                            $status = 'err'; $detail = "$k unreachable: $val"
                        }
                    }
                }
            }
        } else {
            $status = 'err'; $detail = "$bin not on PATH"
        }
    }
    elseif ($p.kind -eq 'http') {
        try {
            Invoke-WebRequest -Uri $p.base_url -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
            $status = 'ok'; $detail = "$($p.base_url) alive"
        } catch {
            $status = 'err'; $detail = "$($p.base_url) unreachable"
        }
    }

    if ($status -eq 'err' -or $status -eq 'warn') { $anyBad = $true }
    $rows += [pscustomobject]@{ NAME = $p.name; STATUS = $status; DETAIL = $detail }
}

$rows | Format-Table -AutoSize | Out-String | Write-Host
$enabled = @($fleet | Where-Object { $_.enabled -eq $true }).Count
Write-Host "$enabled enabled provider(s)."
if ($anyBad) { exit 1 } else { exit 0 }
