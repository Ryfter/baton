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
    [switch]$All,
    [string]$Box,
    [string]$Import,
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$SnapshotPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'model-inventory.json' } else { Join-Path $HOME '.baton/model-inventory.json' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

function ConvertFrom-LmStudioModels {
    <# Normalize LM Studio native GET /api/v1/models JSON to inventory rows.
       The live shape (LM Studio 0.3.x, verified 2026-06-11): top key `models`,
       model id in `key`, `architecture`, `quantization` an OBJECT {name,...},
       `capabilities` an OBJECT of booleans (vision/reasoning/...), loadedness in
       `loaded_instances[]`. Older/OpenAI-ish variants (`data`, `id`, string
       quant, string-array capabilities, `state`) still accepted.
       Tolerant: absent fields -> $null/empty, never throws on shape drift. #>
    param([Parameter(Mandatory)][string]$RawJson)
    $o = $RawJson | ConvertFrom-Json -ErrorAction Stop
    $list = if ($null -ne $o.models) { @($o.models) } else { @($o.data) }
    return @(foreach ($m in $list) {
        $quant = if ($m.quantization -is [string]) { [string]$m.quantization }
                 elseif ($m.quantization.name)     { [string]$m.quantization.name }
                 else { $null }
        # capabilities: object of booleans -> names of the true ones; legacy
        # string array passes through. 'reasoning' lands here either way.
        $flags = @()
        if ($m.capabilities -is [System.Management.Automation.PSCustomObject]) {
            $flags = @($m.capabilities.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object { [string]$_.Name })
        } elseif ($null -ne $m.capabilities) {
            $flags = @(@($m.capabilities) | ForEach-Object { [string]$_ })
        }
        $loaded = if ($null -ne $m.loaded_instances) { @($m.loaded_instances).Count -gt 0 }
                  else { ($m.state -eq 'loaded') }
        [pscustomobject]@{
            id          = $(if ($m.key) { [string]$m.key } else { [string]$m.id })
            type        = $(if ($m.type) { [string]$m.type } else { 'llm' })
            quant       = $quant
            max_context = $(if ($m.max_context_length) { [int]$m.max_context_length } else { $null })
            size_bytes  = $(if ($m.size_bytes) { [long]$m.size_bytes } else { $null })
            flags       = $flags
            loaded      = $loaded
            family      = $(if ($m.architecture) { [string]$m.architecture } else { [string]$m.arch })
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

function Test-FleetPlaceholderUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    if ($Url -match '(?i)example\.(com|org|net)|documentation-only|replace per box') { return $true }
    try {
        $u = [Uri]$Url
        $boxHost = $u.Host
        if ($boxHost -match '^(localhost|127\.0\.0\.1)$') { return $false }
        if ($boxHost -match '^192\.0\.2\.') { return $true }
        if ($boxHost -match '^198\.51\.100\.') { return $true }
        if ($boxHost -match '^203\.0\.113\.') { return $true }
    } catch { }
    return $false
}

function Get-FleetBoxScopeLabel {
    param([string]$BaseUrl)
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return 'unknown' }
    if (Test-FleetPlaceholderUrl -Url $BaseUrl) { return 'placeholder-config' }
    try {
        $u = [Uri]$BaseUrl
        $boxHost = $u.Host.ToLowerInvariant()
        if ($boxHost -in @('localhost', '127.0.0.1', '::1')) { return 'this-mac' }
        if ($boxHost -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') { return 'remote-tailscale' }
        if ($boxHost -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)') { return 'remote-lan' }
        return 'remote-url'
    } catch {
        return 'unknown'
    }
}

function Get-LmLinkContext {
    $lms = Get-Command lms -ErrorAction SilentlyContinue
    if (-not $lms) { return $null }
    try {
        $raw = & $lms.Source link status --json 2>$null
        if (-not $raw) { return $null }
        $o = $raw | ConvertFrom-Json
        $peers = @{}
        foreach ($p in @($o.peers)) {
            if ($p.deviceIdentifier) {
                $peers[[string]$p.deviceIdentifier] = [string]$p.deviceName
            }
        }
        return [pscustomobject]@{
            local_device = [string]$o.deviceName
            local_id     = [string]$o.deviceIdentifier
            peers        = $peers
        }
    } catch {
        return $null
    }
}

function Get-LmStudioHostMap {
    param($LmLinkContext)
    $lms = Get-Command lms -ErrorAction SilentlyContinue
    if (-not $lms) { return @{} }
    try {
        $raw = & $lms.Source ls --json --llm 2>$null
        if (-not $raw) { return @{} }
        $rows = @($raw | ConvertFrom-Json)
        $localName = if ($LmLinkContext -and $LmLinkContext.local_device) { [string]$LmLinkContext.local_device } else { 'this Mac' }
        $peerMap = if ($LmLinkContext -and $LmLinkContext.peers) { $LmLinkContext.peers } else { @{} }
        $map = @{}
        foreach ($r in $rows) {
            $key = [string]$r.modelKey
            if (-not $key) { continue }
            $devId = if ($r.PSObject.Properties.Name -contains 'deviceIdentifier') { [string]$r.deviceIdentifier } else { '' }
            if ([string]::IsNullOrWhiteSpace($devId)) {
                $deviceName = $localName
                $scope = 'this-mac'
            } elseif ($peerMap.Contains($devId)) {
                $deviceName = [string]$peerMap[$devId]
                $scope = 'remote-lmlink'
            } else {
                $deviceName = $devId
                $scope = 'remote-lmlink'
            }
            $map[$key] = [pscustomobject]@{ host_device = $deviceName; storage_scope = $scope }
        }
        return $map
    } catch {
        return @{}
    }
}

function Get-OllamaCliInventory {
    param([string]$FleetPath)
    $fleet = @(Read-Fleet -Path $FleetPath)
    $prov = @($fleet | Where-Object {
        $_.enabled -eq $true -and $_.kind -eq 'cli' -and $_.cost_tier -eq 'local' -and
        [string]$_.command_template -match '(?i)\bollama\s+run\b'
    } | Select-Object -First 1)
    if (-not $prov) { return $null }
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollama) { return $null }
    try {
        $lines = @( & $ollama.Source list 2>$null )
        if ($lines.Count -lt 2) { return [pscustomobject]@{ provider = [string]$prov.name; runtime = 'ollama-cli'; models = @() } }
        $models = [System.Collections.Generic.List[object]]::new()
        foreach ($ln in $lines | Select-Object -Skip 1) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            $parts = @($ln.Trim() -split '\s+', 4)
            if ($parts.Count -lt 2) { continue }
            $size = if ($parts.Count -ge 4) { "$($parts[2]) $($parts[3])" } elseif ($parts.Count -ge 3) { [string]$parts[2] } else { '' }
            $models.Add([pscustomobject]@{
                id          = [string]$parts[0]
                size        = $size
                runtime     = 'ollama-cli'
                host_device = if ($env:HOSTNAME) { [string]$env:HOSTNAME } else { 'this Mac' }
                storage_scope = 'this-mac'
                model_default = ([string]$prov.model_default -eq [string]$parts[0])
            })
        }
        return [pscustomobject]@{
            provider = [string]$prov.name
            runtime  = 'ollama-cli'
            models   = @($models)
        }
    } catch {
        return $null
    }
}

function Get-CloudApiSeats {
    param([string]$FleetPath)
    $fleet = @(Read-Fleet -Path $FleetPath)
    return @($fleet | Where-Object {
        $_.enabled -eq $true -and $_.cost_tier -in @('paid', 'free') -and $_.kind -in @('cli', 'http', 'stdio-json')
    } | ForEach-Object {
        [pscustomobject]@{
            name          = [string]$_.name
            cost_tier     = [string]$_.cost_tier
            kind          = [string]$_.kind
            model_default = if ($_.model_default) { [string]$_.model_default } else { '' }
            note          = 'API/subscription seat — not a local model on this Mac'
        }
    })
}

function Add-InventoryHostTags {
    param(
        [Parameter(Mandatory)]$Inventory,
        $LmLinkContext,
        $HostMap
    )
    foreach ($boxEntry in @($Inventory.boxes)) {
        $scope = Get-FleetBoxScopeLabel -BaseUrl ([string]$boxEntry.base_url)
        $boxEntry | Add-Member -NotePropertyName scope -NotePropertyValue $scope -Force
        $boxEntry | Add-Member -NotePropertyName placeholder -NotePropertyValue (Test-FleetPlaceholderUrl -Url ([string]$boxEntry.base_url)) -Force
        if ($boxEntry.enrich -ne 'lmstudio' -or -not $HostMap -or $HostMap.Count -eq 0) {
            $runtime = if ($boxEntry.enrich -eq 'ollama') { 'ollama-http' } elseif ($boxEntry.enrich -eq 'lmstudio') { 'lm-studio' } else { [string]$boxEntry.enrich }
            foreach ($m in @($boxEntry.models)) {
                $deviceName = switch ($scope) {
                    'this-mac' { if ($LmLinkContext -and $LmLinkContext.local_device) { [string]$LmLinkContext.local_device } else { 'this Mac' } }
                    'placeholder-config' { 'not configured' }
                    default { [string]$boxEntry.base_url }
                }
                $m | Add-Member -NotePropertyName runtime -NotePropertyValue $runtime -Force
                $m | Add-Member -NotePropertyName host_device -NotePropertyValue $deviceName -Force
                $m | Add-Member -NotePropertyName storage_scope -NotePropertyValue $scope -Force
            }
            continue
        }
        foreach ($m in @($boxEntry.models)) {
            $hit = $HostMap[[string]$m.id]
            $deviceName = if ($hit) { [string]$hit.host_device } else { if ($LmLinkContext.local_device) { [string]$LmLinkContext.local_device } else { 'this Mac' } }
            $stor = if ($hit) { [string]$hit.storage_scope } else { 'unknown' }
            $m | Add-Member -NotePropertyName runtime -NotePropertyValue 'lm-studio' -Force
            $m | Add-Member -NotePropertyName host_device -NotePropertyValue $deviceName -Force
            $m | Add-Member -NotePropertyName storage_scope -NotePropertyValue $stor -Force
        }
    }
    return $Inventory
}

function Get-ModelInventoryDisplayRows {
    param(
        $BoxEntry,
        [switch]$All
    )
    $rows = @($BoxEntry.models)
    if ($All) { return $rows }
    return @($rows | Where-Object {
        $_.loaded -eq $true -or @($_.pinned_by).Count -gt 0 -or $_.keep -eq $true
    })
}

function Write-ModelInventoryReport {
    param(
        $View,
        $Recommendations,
        $OllamaCli,
        $CloudSeats,
        $LmLinkContext,
        [switch]$All,
        [string]$SnapshotPath
    )
    if ($LmLinkContext) {
        $peerNames = @($LmLinkContext.peers.Values | Sort-Object -Unique)
        Write-Host "`n-- LM Link --" -ForegroundColor Cyan
        Write-Host ("  this machine: {0}" -f $LmLinkContext.local_device)
        if ($peerNames.Count -gt 0) {
            Write-Host ("  linked remotes: {0}" -f ($peerNames -join ', '))
        } else {
            Write-Host '  linked remotes: (none)'
        }
        Write-Host '  LM Studio catalog merges local + linked models at localhost:1234 — host column shows where each model lives.'
    }

    if ($OllamaCli) {
        Write-Host "`n-- this Mac · ollama CLI ($($OllamaCli.provider)) --" -ForegroundColor Cyan
        if ($OllamaCli.models.Count -eq 0) {
            Write-Host '  (no models installed — run ollama pull <model>)'
        } else {
            foreach ($m in @($OllamaCli.models)) {
                $def = if ($m.model_default) { ' · registry default' } else { '' }
                Write-Host ("  {0} · {1} · ollama-cli{2}" -f $m.id, $m.size, $def)
            }
        }
    }

    foreach ($boxEntry in @($View.boxes)) {
        $scope = if ($boxEntry.scope) { [string]$boxEntry.scope } else { Get-FleetBoxScopeLabel -BaseUrl ([string]$boxEntry.base_url) }
        $scopeLabel = switch ($scope) {
            'this-mac'           { 'this Mac' }
            'remote-lan'         { 'remote LAN' }
            'remote-tailscale'   { 'remote Tailscale' }
            'placeholder-config' { 'PLACEHOLDER — edit fleet.yaml' }
            default              { $scope }
        }
        $runtime = if ($boxEntry.enrich -eq 'ollama') { 'ollama HTTP' } else { 'LM Studio HTTP' }
        Write-Host "`n== $scopeLabel · $($boxEntry.base_url) · $runtime [$($boxEntry.providers -join ', ')] ==" -ForegroundColor Cyan
        if ($boxEntry.placeholder) {
            Write-Host '  This URL is a documentation placeholder (192.0.2.x TEST-NET), not a cached travel-network IP. Set a real address in ~/.baton/fleet.yaml or disable the provider.' -ForegroundColor Yellow
        }
        if (-not $boxEntry.reachable) {
            Write-Host "  OFFLINE: $($boxEntry.error)" -ForegroundColor Yellow
            continue
        }
        $displayRows = @(Get-ModelInventoryDisplayRows -BoxEntry $boxEntry -All:$All)
        $total = @($boxEntry.models).Count
        if (-not $All -and $displayRows.Count -lt $total) {
            Write-Host ("  showing {0} of {1} models (loaded + registry defaults). Use --all for full catalog." -f $displayRows.Count, $total)
        }
        if ($displayRows.Count -eq 0) {
            Write-Host '  (nothing loaded or registered on this box right now)'
            continue
        }
        $displayRows | Sort-Object host_device, { -([long]($_.size_bytes ?? 0)) } |
            Format-Table @{n='model';e={$_.id}}, @{n='runtime';e={$_.runtime}}, @{n='host';e={$_.host_device}},
                         @{n='loaded';e={$_.loaded}}, @{n='default-for';e={$_.pinned_by -join ','}},
                         @{n='claims';e={$_.claims -join ','}} -AutoSize | Out-Host
    }

    if ($CloudSeats -and $CloudSeats.Count -gt 0) {
        Write-Host "`n-- cloud API seats (not local LLMs) --" -ForegroundColor Cyan
        Write-Host '  These are subscription/API providers in fleet.yaml — Claude, Codex, OpenRouter, etc.'
        $CloudSeats | Sort-Object cost_tier, name |
            Format-Table @{n='provider';e={$_.name}}, @{n='tier';e={$_.cost_tier}}, @{n='kind';e={$_.kind}},
                         @{n='default-model';e={$_.model_default}} -AutoSize | Out-Host
    }

    Write-Host "`n-- recommendations ($($Recommendations.Count)) --" -ForegroundColor Cyan
    foreach ($r in @($Recommendations)) { Write-Host "  * $r" }
    Write-Host "`nsnapshot: $SnapshotPath"
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
            $note = if ($boxEntry.placeholder) {
                "box $($boxEntry.base_url) offline (placeholder URL — update fleet.yaml): $($boxEntry.providers -join ', ')"
            } else {
                "box $($boxEntry.base_url) offline — inventory stale for: $($boxEntry.providers -join ', ')"
            }
            [void]$recs.Add($note)
            continue
        }
        $ids = @($boxEntry.models | ForEach-Object { $_.id })
        # 'auto' = unpinned sentinel — nothing concrete to verify; skip it.
        foreach ($p in @($fleet | Where-Object { $boxEntry.providers -contains $_.name -and $_.model_default -and $_.model_default -ne 'auto' })) {
            if ($ids -notcontains [string]$p.model_default) {
                [void]$recs.Add("MISSING DEFAULT MODEL: provider '$($p.name)' expects '$($p.model_default)' on $($boxEntry.base_url)")
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
            [void]$recs.Add("UNREGISTERED SPECIALIST: '$($m.id)' ($($m.type)) installed but no provider default set")
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
$lmLink = Get-LmLinkContext
$hostMap = Get-LmStudioHostMap -LmLinkContext $lmLink
$inv = Add-InventoryHostTags -Inventory $inv -LmLinkContext $lmLink -HostMap $hostMap
$ollamaCli = Get-OllamaCliInventory -FleetPath $FleetPath
$cloudSeats = @(Get-CloudApiSeats -FleetPath $FleetPath)
if ($lmLink) { $inv | Add-Member -NotePropertyName lm_link -NotePropertyValue $lmLink -Force }
if ($ollamaCli) { $inv | Add-Member -NotePropertyName ollama_cli -NotePropertyValue $ollamaCli -Force }
if ($cloudSeats.Count -gt 0) { $inv | Add-Member -NotePropertyName cloud_seats -NotePropertyValue $cloudSeats -Force }
# Write the FULL inventory snapshot first — --box is a display-only filter and must
# not corrupt the canonical snapshot with a one-box subset.
$snapshot = $inv | ConvertTo-Json -Depth 10
Set-JsonFileAtomic -Path $SnapshotPath -Json $snapshot
$view = if ($Box) { [pscustomobject]@{ generated_at = $inv.generated_at; boxes = @($inv.boxes | Where-Object { $_.providers -contains $Box }) } } else { $inv }
if ($Json) { Write-Output $snapshot; exit 0 }

$recs = @(Get-InventoryRecommendations -Inventory $view -FleetPath $FleetPath)
Write-ModelInventoryReport -View $view -Recommendations $recs -OllamaCli $ollamaCli -CloudSeats $cloudSeats `
    -LmLinkContext $lmLink -All:$All -SnapshotPath $SnapshotPath
