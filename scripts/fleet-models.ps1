#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Model inventory for /baton:models. Probes each enabled local http provider's box
  (LM Studio native /api/v1/models; ollama /api/tags), joins with registry pins,
  claims, and the keep_list, writes a snapshot, prints a table + recommendations.
  Recommend-only: never installs or deletes a model.

.NOTES
  Dot-source for the function library (tests do); run as a script for the command.
  -Import hands off to Import-GauntletScorecard (routing-learn.ps1).
#>
param(
    [switch]$Json,
    [string]$Box,
    [string]$Import,
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$SnapshotPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'model-inventory.json' } else { Join-Path $HOME '.baton/model-inventory.json' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

function ConvertFrom-LmStudioModels {
    <# Normalize LM Studio native GET /api/v1/models JSON to inventory rows.
       Tolerant: absent fields -> $null/empty, never throws on shape drift. #>
    param([Parameter(Mandatory)][string]$RawJson)
    $o = $RawJson | ConvertFrom-Json -ErrorAction Stop
    return @(foreach ($m in @($o.data)) {
        [pscustomobject]@{
            id          = [string]$m.id
            type        = $(if ($m.type) { [string]$m.type } else { 'llm' })
            quant       = [string]$m.quantization
            max_context = $(if ($m.max_context_length) { [int]$m.max_context_length } else { $null })
            size_bytes  = $(if ($m.size_bytes) { [long]$m.size_bytes } else { $null })
            flags       = @(@($m.capabilities) | ForEach-Object { [string]$_ })
            loaded      = ($m.state -eq 'loaded')
            family      = [string]$m.arch
        }
    })
}

function ConvertFrom-OllamaTags {
    <# Normalize ollama GET /api/tags JSON to the same row shape (less metadata). #>
    param([Parameter(Mandatory)][string]$RawJson)
    $o = $RawJson | ConvertFrom-Json -ErrorAction Stop
    return @(foreach ($m in @($o.models)) {
        [pscustomobject]@{
            id          = [string]$m.name
            type        = 'llm'
            quant       = [string]$m.details.quantization_level
            max_context = $null
            size_bytes  = $(if ($m.size) { [long]$m.size } else { $null })
            flags       = @()
            loaded      = $null
            family      = [string]$m.details.family
        }
    })
}

function Get-ModelInventory {
    <# Probe each enabled local http provider's box, deduped by base_url (lm-studio +
       lm-studio-small share one server — ONE probe). Enrichment kind by provider name
       prefix: ollama* -> /api/tags, anything else -> LM Studio native /api/v1/models.
       -Prober (param: url -> raw json string) injectable; default = HTTP GET 10s.
       Unreachable boxes are marked, never fatal (wraith2 is often off). #>
    param(
        [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
        [scriptblock]$Prober
    )
    if (-not $Prober) {
        $Prober = { param($url) (Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing).Content }
    }
    $locals = @(Read-Fleet -Path $FleetPath | Where-Object {
        $_.enabled -eq $true -and $_.cost_tier -eq 'local' -and $_.kind -eq 'http' -and $_.base_url
    })
    $byUrl = [ordered]@{}
    foreach ($p in $locals) {
        if (-not $byUrl.Contains([string]$p.base_url)) { $byUrl[[string]$p.base_url] = [System.Collections.ArrayList]@() }
        [void]$byUrl[[string]$p.base_url].Add($p)
    }
    $boxes = @(foreach ($url in $byUrl.Keys) {
        $provs = $byUrl[$url]
        $enrich = if ([string]$provs[0].name -like 'ollama*') { 'ollama' } else { 'lmstudio' }
        $probeUrl = if ($enrich -eq 'ollama') { "$url/api/tags" } else { "$url/api/v1/models" }
        $models = @(); $reachable = $true; $err = $null
        try {
            $raw = [string](& $Prober $probeUrl)
            $models = if ($enrich -eq 'ollama') { @(ConvertFrom-OllamaTags -RawJson $raw) } else { @(ConvertFrom-LmStudioModels -RawJson $raw) }
        } catch {
            $reachable = $false; $err = $_.Exception.Message
        }
        [pscustomobject]@{
            base_url = [string]$url; enrich = $enrich
            providers = @($provs | ForEach-Object { [string]$_.name })
            reachable = $reachable; error = $err; models = $models
        }
    })
    return [pscustomobject]@{ generated_at = (Get-Date).ToString('o'); boxes = $boxes }
}

function Add-InventoryTags {
    <# Join inventory rows with the registry: pinned_by (providers whose model_default
       is this model), claims (those providers' capabilities), keep (keep_list glob),
       unregistered (no pin). Returns the mutated inventory. #>
    param(
        [Parameter(Mandatory)]$Inventory,
        [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
    )
    $fleet = @(Read-Fleet -Path $FleetPath)
    $keep = @(Get-FleetKeepList -Path $FleetPath)
    foreach ($boxEntry in @($Inventory.boxes)) {
        $boxProviders = @($fleet | Where-Object { $boxEntry.providers -contains $_.name })
        foreach ($m in @($boxEntry.models)) {
            $pinned = @($boxProviders | Where-Object { [string]$_.model_default -eq $m.id })
            $claims = @($pinned | Where-Object { $_.capabilities } | ForEach-Object { @($_.capabilities) })
            $m | Add-Member -NotePropertyName pinned_by    -NotePropertyValue @($pinned | ForEach-Object { [string]$_.name }) -Force
            $m | Add-Member -NotePropertyName claims       -NotePropertyValue @($claims | Select-Object -Unique) -Force
            $m | Add-Member -NotePropertyName keep         -NotePropertyValue ([bool](@($keep | Where-Object { $m.id -like $_ }).Count)) -Force
            $m | Add-Member -NotePropertyName unregistered -NotePropertyValue ($pinned.Count -eq 0) -Force
        }
    }
    return $Inventory
}

function Get-InventoryRecommendations {
    <# Recommend-only heuristics over a tagged inventory. Returns string[]:
       MISSING PIN / JUDGE RISK / NEAR-DUP / UNREGISTERED SPECIALIST / offline notes.
       keep-tagged models are exempt from culling-flavored lines (hard exemption). #>
    param(
        [Parameter(Mandatory)]$Inventory,
        [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
    )
    $recs = [System.Collections.ArrayList]@()
    $fleet = @(Read-Fleet -Path $FleetPath)
    foreach ($boxEntry in @($Inventory.boxes)) {
        if (-not $boxEntry.reachable) {
            [void]$recs.Add("box $($boxEntry.base_url) offline — inventory stale for: $($boxEntry.providers -join ', ')")
            continue
        }
        $ids = @($boxEntry.models | ForEach-Object { $_.id })
        # 'auto' = unpinned sentinel — nothing concrete to verify; skip it.
        foreach ($p in @($fleet | Where-Object { $boxEntry.providers -contains $_.name -and $_.model_default -and $_.model_default -ne 'auto' })) {
            if ($ids -notcontains [string]$p.model_default) {
                [void]$recs.Add("MISSING PIN: provider '$($p.name)' pins '$($p.model_default)' but it is not installed on $($boxEntry.base_url)")
            }
        }
        foreach ($m in @($boxEntry.models)) {
            if ($m.flags -contains 'reasoning' -and $m.claims -contains 'judge') {
                [void]$recs.Add("JUDGE RISK: '$($m.id)' claims judge but is reasoning-flagged (thinking preamble breaks strict-JSON parsing)")
            }
        }
        $dupPool = @($boxEntry.models | Where-Object { $_.size_bytes -and $_.family -and -not $_.keep -and @($_.pinned_by).Count -eq 0 })
        for ($i = 0; $i -lt $dupPool.Count; $i++) {
            for ($j = $i + 1; $j -lt $dupPool.Count; $j++) {
                $a = $dupPool[$i]; $b = $dupPool[$j]
                if ($a.family -ne $b.family) { continue }
                $hi = [Math]::Max([long]$a.size_bytes, [long]$b.size_bytes)
                $lo = [Math]::Min([long]$a.size_bytes, [long]$b.size_bytes)
                if ($hi -gt 0 -and (($hi - $lo) / [double]$hi) -le 0.15) {
                    [void]$recs.Add("NEAR-DUP: '$($a.id)' and '$($b.id)' (family '$($a.family)', sizes within 15%) — consider keeping one")
                }
            }
        }
        foreach ($m in @($boxEntry.models | Where-Object { $_.unregistered -and -not $_.keep -and ($_.type -in @('embedding','vlm')) })) {
            [void]$recs.Add("UNREGISTERED SPECIALIST: '$($m.id)' ($($m.type)) installed but no provider pins it")
        }
    }
    return @($recs)
}

# ─── script entry (skipped when dot-sourced by tests) ───
if ($MyInvocation.InvocationName -eq '.') { return }

if ($Import) {
    . (Join-Path $PSScriptRoot 'routing-lib.ps1')   # loads routing-learn (Import-GauntletScorecard)
    $r = Import-GauntletScorecard -Path $Import -FleetPath $FleetPath
    if ($r.already) { Write-Host "scorecard run '$($r.run_id)' already imported — nothing to do" }
    else { Write-Host "imported $($r.imported) cells (skipped $($r.skipped), unmapped $($r.unmapped)) from run '$($r.run_id)'" }
    exit 0
}

$inv = Get-ModelInventory -FleetPath $FleetPath
$inv = Add-InventoryTags -Inventory $inv -FleetPath $FleetPath
# Write the FULL inventory snapshot first — --box is a display-only filter and must
# not corrupt the canonical snapshot with a one-box subset.
$snapshot = $inv | ConvertTo-Json -Depth 8
Set-JsonFileAtomic -Path $SnapshotPath -Json $snapshot
$view = if ($Box) { [pscustomobject]@{ generated_at = $inv.generated_at; boxes = @($inv.boxes | Where-Object { $_.providers -contains $Box }) } } else { $inv }
if ($Json) { Write-Output $snapshot; exit 0 }

foreach ($boxEntry in @($view.boxes)) {
    Write-Host "`n== $($boxEntry.base_url) [$($boxEntry.enrich)] providers: $($boxEntry.providers -join ', ') ==" -ForegroundColor Cyan
    if (-not $boxEntry.reachable) { Write-Host "  OFFLINE: $($boxEntry.error)" -ForegroundColor Yellow; continue }
    $boxEntry.models | Sort-Object { -([long]($_.size_bytes ?? 0)) } |
        Format-Table @{n='model';e={$_.id}}, @{n='type';e={$_.type}}, @{n='quant';e={$_.quant}},
                     @{n='ctx';e={$_.max_context}}, @{n='loaded';e={$_.loaded}},
                     @{n='pins';e={$_.pinned_by -join ','}}, @{n='claims';e={$_.claims -join ','}},
                     @{n='keep';e={$_.keep}} -AutoSize | Out-Host
}
$recs = @(Get-InventoryRecommendations -Inventory $view -FleetPath $FleetPath)
Write-Host "`n-- recommendations ($($recs.Count)) --" -ForegroundColor Cyan
foreach ($r in $recs) { Write-Host "  * $r" }
Write-Host "`nsnapshot: $SnapshotPath"
