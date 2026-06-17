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

function Test-GhAuth {
    # Preflight: is gh authenticated? Default invoker shells real gh and sets $LASTEXITCODE.
    param([scriptblock]$GhInvoker = { param($argv) & gh @argv })
    try { & $GhInvoker @('auth','status') *> $null; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}

function Get-RepoIssues {
    param(
        [string]$Repo, [int]$Limit = 200,
        [scriptblock]$GhInvoker = { param($argv) & gh @argv }
    )
    $argv = @('issue','list','--state','open','--limit',"$Limit",'--json','number,title,body,labels,assignees,url')
    if ($Repo) { $argv += @('--repo',$Repo) }
    $json = ((& $GhInvoker $argv) | Out-String).Trim()
    if (-not $json) { return ,([object[]]@()) }
    return ,([object[]]@($json | ConvertFrom-Json))
}

function Resolve-ProjectFields {
    param(
        [Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][int]$ProjectNumber,
        [scriptblock]$GhInvoker = { param($argv) & gh @argv }
    )
    $argv = @('project','field-list',"$ProjectNumber",'--owner',$Owner,'--format','json','--limit','100')
    $json = ((& $GhInvoker $argv) | Out-String).Trim()
    if (-not $json) { return @{} }
    $obj = $json | ConvertFrom-Json
    $map = @{}
    foreach ($f in @($obj.fields)) {
        $entry = @{ id=[string]$f.id; type=[string]$f.type; options=@{} }
        foreach ($o in @($f.options)) { if ($o.name) { $entry.options[[string]$o.name] = [string]$o.id } }
        if ($f.name) { $map[[string]$f.name] = $entry }
    }
    return $map
}

function Ensure-ProjectFields {
    param(
        [Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][int]$ProjectNumber,
        [hashtable]$FieldMap,
        [scriptblock]$GhInvoker = { param($argv) & gh @argv }
    )
    if ($null -eq $FieldMap) { $FieldMap = @{} }
    if (-not $FieldMap.ContainsKey('Priority')) {
        $argv = @('project','field-create',"$ProjectNumber",'--owner',$Owner,'--name','Priority','--data-type','SINGLE_SELECT','--single-select-options','P0,P1,P2,P3,P4')
        & $GhInvoker $argv | Out-Null
    }
    return (Resolve-ProjectFields -Owner $Owner -ProjectNumber $ProjectNumber -GhInvoker $GhInvoker)
}

function Resolve-ProjectItems {
    param(
        [Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][int]$ProjectNumber,
        [scriptblock]$GhInvoker = { param($argv) & gh @argv }
    )
    $argv = @('project','item-list',"$ProjectNumber",'--owner',$Owner,'--format','json','--limit','200')
    $json = ((& $GhInvoker $argv) | Out-String).Trim()
    if (-not $json) { return @{} }
    $obj = $json | ConvertFrom-Json
    $map = @{}
    foreach ($it in @($obj.items)) {
        $n = $null
        if ($it.content -and $it.content.number) { $n = [int]$it.content.number }
        elseif ($it.number) { $n = [int]$it.number }
        if ($null -eq $n) { continue }
        $cur = @{}
        if ($it.status)   { $cur['Status']   = [string]$it.status }
        if ($it.priority) { $cur['Priority'] = [string]$it.priority }
        $map["$n"] = @{ item_id=[string]$it.id; fields=$cur }
    }
    return $map
}
