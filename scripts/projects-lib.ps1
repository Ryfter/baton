#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Sprint 3 — GitHub Projects sync. Maps Triage Agent classification onto GitHub
  labels (classify) + Project v2 single-select fields (decide). All GitHub I/O is
  routed through an injectable $GhInvoker so tests never touch a real repo/board.
#>

# A triage result is "decisive" (worth writing labels+fields) only when it named a
# concrete type and met the confidence floor. Otherwise it is a fallback -> needs-triage.
$script:TriageDecisiveConfidence = 0.6

function Test-TriageDecisive {
    param([Parameter(Mandatory)][hashtable]$Triage)
    $type = [string]$Triage.type
    if (-not $type -or $type -eq 'unknown') { return $false }
    $conf = if ($null -ne $Triage.confidence) { [double]$Triage.confidence } else { 0.0 }
    return ($conf -ge $script:TriageDecisiveConfidence)
}

function ConvertTo-SyncLabels {
    # Triage hashtable -> desired label string[] (classify dimensions). Indecisive -> needs-triage.
    param([Parameter(Mandatory)][hashtable]$Triage)
    if (-not (Test-TriageDecisive -Triage $Triage)) { return ([string[]]@('needs-triage')) }
    $labels = New-Object System.Collections.Generic.List[string]
    $type = [string]$Triage.type
    if ($type) { $labels.Add("type:$($type.ToLowerInvariant())") }
    $area = [string]$Triage.area
    if ($area -and $area -ne 'null') { $labels.Add("area:$area") }
    $risk = [string]$Triage.risk
    if ($risk) { $labels.Add("risk:$($risk.ToLowerInvariant())") }
    $est = [string]$Triage.estimate
    if ($est) { $labels.Add("estimate:$est") }
    $plat = [string]$Triage.recommended_platform
    if ($plat) { $labels.Add("route:$plat") }
    return ([string[]]$labels.ToArray())
}

function ConvertTo-SyncFieldValues {
    # Triage hashtable -> desired Project field values (decide dimensions). Indecisive -> empty.
    param([Parameter(Mandatory)][hashtable]$Triage)
    if (-not (Test-TriageDecisive -Triage $Triage)) { return @{} }
    $f = @{}
    $pri = [string]$Triage.priority
    if ($pri) { $f['Priority'] = $pri.ToUpperInvariant() }
    $f['Status'] = 'Todo'
    return $f
}

function Get-IssueTriageState {
    # From an issue's current labels: is it already triaged (has a type:* label)?
    param([Parameter(Mandatory)]$Issue)
    $names = @()
    foreach ($l in @($Issue.labels)) {
        if ($null -eq $l) { continue }
        if ($l -is [string]) { $names += $l }
        elseif ($l.name)     { $names += [string]$l.name }
    }
    $triaged = [bool]@($names | Where-Object { $_ -like 'type:*' }).Count
    return @{ triaged = $triaged; existing_labels = ([string[]]$names) }
}

function Build-SyncPlan {
    # PURE (no gh): issues + per-issue triage + field map -> ordered per-issue plan.
    # Each already-present label / already-correct field / absent field becomes a skip.
    param(
        [Parameter(Mandatory)][object[]]$Issues,
        [hashtable]$Triages = @{},
        [hashtable]$FieldMap = @{},
        [hashtable]$CurrentFields = @{},
        [hashtable]$ProjectItemNumbers = @{},
        [hashtable]$ClassifyWorkers = @{}
    )
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($iss in @($Issues)) {
        $num = [int]$iss.number
        $key = "$num"
        $state = Get-IssueTriageState -Issue $iss
        $existing = @{}; foreach ($n in $state.existing_labels) { $existing[$n] = $true }
        $entry = [ordered]@{
            number = $num; url = [string]$iss.url; triaged = $state.triaged
            classify_worker = $null; add_labels = @(); set_fields = @()
            add_to_project = $false; skips = @()
        }
        $triage = if ($Triages.ContainsKey($key)) { $Triages[$key] } else { $null }

        if (-not $state.triaged -and $null -eq $triage) {
            $entry.classify_worker = if ($ClassifyWorkers.ContainsKey($key)) { $ClassifyWorkers[$key] } else { '(unresolved)' }
            $entry.skips += "untriaged — would classify (no token spend in dry-run)"
            $plan.Add([pscustomobject]$entry); continue
        }
        if ($null -eq $triage) {
            $entry.skips += "already triaged — no reclassify"
            if (-not $ProjectItemNumbers.ContainsKey($key)) { $entry.add_to_project = $true }
            $plan.Add([pscustomobject]$entry); continue
        }

        foreach ($lab in (ConvertTo-SyncLabels -Triage $triage)) {
            if ($existing.ContainsKey($lab)) { $entry.skips += "label $lab already present" }
            else { $entry.add_labels += $lab }
        }
        $wantFields = ConvertTo-SyncFieldValues -Triage $triage
        foreach ($fname in $wantFields.Keys) {
            $val = [string]$wantFields[$fname]
            if (-not $FieldMap.ContainsKey($fname)) { $entry.skips += "field '$fname' not found on project"; continue }
            $fmeta = $FieldMap[$fname]
            $optId = if ($fmeta.options -and $fmeta.options.ContainsKey($val)) { [string]$fmeta.options[$val] } else { $null }
            if (-not $optId) { $entry.skips += "field '$fname' has no option '$val'"; continue }
            $cur = if ($CurrentFields.ContainsKey($key) -and $CurrentFields[$key].ContainsKey($fname)) { [string]$CurrentFields[$key][$fname] } else { $null }
            if ($cur -eq $val) { $entry.skips += "field '$fname' already '$val'"; continue }
            $entry.set_fields += @{ field=$fname; field_id=[string]$fmeta.id; value=$val; option_id=$optId }
        }
        if (-not $ProjectItemNumbers.ContainsKey($key)) { $entry.add_to_project = $true }
        $plan.Add([pscustomobject]$entry)
    }
    return ,([object[]]$plan.ToArray())
}
