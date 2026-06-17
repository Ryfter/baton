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
