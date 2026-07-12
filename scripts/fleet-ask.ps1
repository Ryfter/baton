#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared runner behind /baton:codex|grok|gemini|agy — dispatch one fleet model,
  journaled + Governor-metered, and print its answer + a token footer.
.DESCRIPTION
  Delegates to Invoke-Fleet (the hardened dispatch path). Reads the prompt inline
  or from a file (the 965-byte escape hatch). `--tier all` runs every named tier
  (boundary tester). Errors politely: unknown/disabled provider or missing prompt
  -> stderr + exit 2.
#>
param(
    [Parameter(Mandatory)][string]$Provider,
    [string]$Prompt,
    [string]$PromptFile,
    [string]$Tier,
    [string]$FleetPath
)

. "$PSScriptRoot/fleet-lib.ps1"

function Write-AskError($msg) { [Console]::Error.WriteLine($msg) }

# Resolve the fleet.yaml path (test override -> BATON_HOME default).
$path = if ($FleetPath) { $FleetPath } else { Join-Path (Get-BatonHome) 'fleet.yaml' }

$prov = Get-FleetProvider -Name $Provider -Path $path
if (-not $prov) { Write-AskError "provider '$Provider' not found in $path"; exit 2 }
if ($prov.enabled -ne $true) { Write-AskError "provider '$Provider' is disabled in fleet.yaml"; exit 2 }

# Prompt: file wins (long/quote-heavy), else inline.
$promptText = if ($PromptFile) {
    if (-not (Test-Path $PromptFile)) { Write-AskError "prompt file not found: $PromptFile"; exit 2 }
    Get-Content -LiteralPath $PromptFile -Raw
} else { $Prompt }
if ([string]::IsNullOrWhiteSpace($promptText)) { Write-AskError "no prompt given (-Prompt or -PromptFile)"; exit 2 }

function Invoke-One($tierName) {
    $r = Invoke-Fleet -Name $Provider -Prompt $promptText -Path $path -Tier $tierName
    Write-Host ([string]$r.stdout)
    $label = if ($tierName) { "$Provider/$tierName" } else { $Provider }
    Write-Host "-- $label | $($r.duration_s)s | exit:$($r.exit_code) | tok:$($r.tokens)($($r.tokens_basis))"
    return [int]$r.exit_code
}

if ($Tier -eq 'all') {
    $names = @(Get-FleetProviderTierNames -Provider $prov)
    if ($names.Count -eq 0) { Write-AskError "provider '$Provider' defines no tiers"; exit 2 }
    $worst = 0
    foreach ($n in $names) {
        Write-Host "=== tier: $n ==="
        $code = Invoke-One $n
        if ($code -ne 0) { $worst = $code }
    }
    exit $worst
} else {
    exit (Invoke-One $Tier)
}
