#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared runner behind /baton:codex|grok|gemini|agy — dispatch one fleet model,
  journaled + Governor-metered, and print its answer + a token footer.
.DESCRIPTION
  Delegates to Invoke-Fleet (the hardened dispatch path). Reads the prompt inline
  or from a file (the 965-byte escape hatch). `--tier all` runs every named tier
  (boundary tester). Errors politely: unknown/disabled provider, unknown tier, or
  missing prompt -> stderr + exit 2.
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
    if (-not (Test-Path -LiteralPath $PromptFile)) { Write-AskError "prompt file not found: $PromptFile"; exit 2 }
    Get-Content -LiteralPath $PromptFile -Raw
} else { $Prompt }
if ([string]::IsNullOrWhiteSpace($promptText)) { Write-AskError "no prompt given (-Prompt or -PromptFile)"; exit 2 }

# Cap --tier all so a misconfigured fleet.yaml cannot fan out unbounded paid calls.
$script:MaxTierAll = 16

function Resolve-AskTierList {
    param([string]$TierArg, [hashtable]$ProviderRow)
    if (-not $TierArg) { return ,@($null) }  # single default (no named tier)
    if ($TierArg -eq 'all') {
        $names = @(Get-FleetProviderTierNames -Provider $ProviderRow)
        if ($names.Count -eq 0) {
            Write-AskError "provider '$Provider' defines no tiers"
            exit 2
        }
        if ($names.Count -gt $script:MaxTierAll) {
            Write-AskError "provider '$Provider' has $($names.Count) tiers (cap $script:MaxTierAll for --tier all)"
            exit 2
        }
        return ,$names
    }
    if (-not (Test-FleetTierName -Name $TierArg)) {
        Write-AskError "invalid tier name '$TierArg' (use word chars, dot, hyphen)"
        exit 2
    }
    $valid = @(Get-FleetProviderTierNames -Provider $ProviderRow)
    if ($valid -notcontains $TierArg) {
        $list = if ($valid.Count) { $valid -join ', ' } else { '(none defined)' }
        Write-AskError "unknown tier '$TierArg' for provider '$Provider' — valid: $list"
        exit 2
    }
    $frag = Get-FleetProviderTier -Provider $ProviderRow -Tier $TierArg
    if (-not $frag) {
        # A legitimately-empty fragment (tier defined as '') dispatches with default
        # args — allow it. Only refuse when a NON-empty fragment was rejected
        # (shell metacharacters) by Get-FleetProviderTier.
        $rawFrag = [string]$ProviderRow["tier_$TierArg"]
        if (-not [string]::IsNullOrWhiteSpace($rawFrag)) {
            Write-AskError "tier '$TierArg' for provider '$Provider' has an unsafe fragment (shell metacharacters refused)"
            exit 2
        }
    }
    return ,@($TierArg)
}

function Invoke-One($tierName) {
    $r = Invoke-Fleet -Name $Provider -Prompt $promptText -Path $path -Tier $tierName
    Write-Host ([string]$r.stdout)
    $label = if ($tierName) { "$Provider/$tierName" } else { $Provider }
    Write-Host "-- $label | $($r.duration_s)s | exit:$($r.exit_code) | tok:$($r.tokens)($($r.tokens_basis))"
    return [int]$r.exit_code
}

$tiersToRun = Resolve-AskTierList -TierArg $Tier -ProviderRow $prov
$worst = 0
foreach ($n in $tiersToRun) {
    if ($Tier -eq 'all') { Write-Host "=== tier: $n ===" }
    $code = Invoke-One $n
    if ($code -ne 0) { $worst = $code }
}
exit $worst
