# GitHub Projects Sync (Sprint 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync Triage Agent classification to GitHub as labels (classify) + Project v2 single-select fields (decide), dry-run by default, all via the `gh` CLI behind an injectable test seam.

**Architecture:** A pure mapping/planning core (`ConvertTo-SyncLabels`, `ConvertTo-SyncFieldValues`, `Get-IssueTriageState`, `Build-SyncPlan`) with zero I/O, plus a `gh`-touching I/O layer (`Get-RepoIssues`, `Resolve-ProjectFields`, `Ensure-ProjectFields`, `Resolve-ProjectItems`, `Test-GhAuth`, `Invoke-SyncPlan`) where every function takes `[scriptblock]$GhInvoker` defaulted to real `gh` and stubbed in tests. A CLI (`fleet-projects.ps1`) wires it: `init` (one-time) + `sync` (dry-run default, `--apply`).

**Tech Stack:** PowerShell 7, `gh` CLI 2.86.0 (`gh project` subcommands), hand-rolled `Check($n,$c)` test harness (no module deps), JSONL-free (reads live GitHub via stubbed gh).

**Spec:** `docs/superpowers/specs/2026-06-16-github-projects-sync-sprint3-design.md`

**Critical conventions (read before starting):**
- Tests NEVER touch a real repo, board, or model. gh is always stubbed via `-GhInvoker`; triage via injected dispatcher / canned object.
- Array returns that must not flatten use the unary-comma idiom: `return ,([object[]]$x)`.
- `$Input` is a PowerShell automatic variable — never name a parameter `-Input` (Sprint 1 trap). `$Event` likewise (Sprint 2 trap). No such names here.
- Match existing style: `scripts/idea-lib.ps1` for the gh idioms, `scripts/test-usage.ps1` for the test harness.

---

### Task 1: Pure mapping functions + test scaffold

**Files:**
- Create: `scripts/projects-lib.ps1`
- Test: `scripts/test-projects.ps1`

- [ ] **Step 1: Write the failing tests**

Create `scripts/test-projects.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/projects-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: pure mapping ----
    $decisive = @{ type='bug'; priority='P1'; estimate='M'; risk='medium'; area='routing'
                   recommended_platform='Codex'; confidence=0.9 }
    $labels = ConvertTo-SyncLabels -Triage $decisive
    Check 'T1 decisive labels include type:bug' ($labels -contains 'type:bug')
    Check 'T2 decisive labels include area:routing' ($labels -contains 'area:routing')
    Check 'T3 decisive labels include risk:medium' ($labels -contains 'risk:medium')
    Check 'T4 decisive labels include estimate:M' ($labels -contains 'estimate:M')
    Check 'T5 decisive labels include route:Codex' ($labels -contains 'route:Codex')

    $noArea = @{ type='docs'; priority='P3'; estimate='S'; risk='low'; area=$null; confidence=0.8 }
    Check 'T6 null area omitted' (-not (@(ConvertTo-SyncLabels -Triage $noArea) | Where-Object { $_ -like 'area:*' }))

    $fallback = @{ type='unknown'; priority='P3'; confidence=0.40 }
    Check 'T7 fallback -> needs-triage only' (@(ConvertTo-SyncLabels -Triage $fallback) -join ',' -eq 'needs-triage')

    $fields = ConvertTo-SyncFieldValues -Triage $decisive
    Check 'T8 decisive fields set Priority=P1' ($fields['Priority'] -eq 'P1')
    Check 'T9 decisive fields set Status=Todo' ($fields['Status'] -eq 'Todo')
    Check 'T10 fallback fields empty' ((ConvertTo-SyncFieldValues -Triage $fallback).Count -eq 0)

    $issTriaged   = [pscustomobject]@{ number=1; labels=@(@{name='type:bug'}, @{name='area:x'}) }
    $issUntriaged = [pscustomobject]@{ number=2; labels=@(@{name='needs-triage'}) }
    Check 'T11 issue with type:* is triaged' ((Get-IssueTriageState -Issue $issTriaged).triaged)
    Check 'T12 issue without type:* is untriaged' (-not (Get-IssueTriageState -Issue $issUntriaged).triaged)
    Check 'T13 existing labels captured' ((Get-IssueTriageState -Issue $issTriaged).existing_labels -contains 'type:bug')
}
finally {
    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "FAILED: $script:fail check(s)"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: FAIL — `projects-lib.ps1` does not exist / functions not defined.

- [ ] **Step 3: Implement the pure mapping functions**

Create `scripts/projects-lib.ps1`:

```powershell
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
    if (-not (Test-TriageDecisive -Triage $Triage)) { return ,([string[]]@('needs-triage')) }
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
    return ,([string[]]$labels.ToArray())
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
    return @{ triaged = $triaged; existing_labels = ,([string[]]$names) }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: ALL CHECKS PASS (T1–T13).

- [ ] **Step 5: Commit**

```bash
git add scripts/projects-lib.ps1 scripts/test-projects.ps1
git commit -m "feat(projects): pure triage->label/field mapping (Sprint 3 Task 1)"
```

---

### Task 2: Build-SyncPlan (pure planner)

**Files:**
- Modify: `scripts/projects-lib.ps1` (append)
- Test: `scripts/test-projects.ps1` (append before the `finally`)

- [ ] **Step 1: Write the failing tests**

Insert into `scripts/test-projects.ps1` immediately before the `}\nfinally {` block:

```powershell
    # ---- Task 2: Build-SyncPlan (pure) ----
    $fieldMap = @{
        Priority = @{ id='PF_pri'; type='ProjectV2SingleSelectField'; options=@{ P0='o0'; P1='o1'; P2='o2'; P3='o3'; P4='o4' } }
        Status   = @{ id='PF_sta'; type='ProjectV2SingleSelectField'; options=@{ Todo='oT'; 'In Progress'='oP'; Done='oD' } }
    }
    $issues = @(
        [pscustomobject]@{ number=10; url='https://x/10'; labels=@() }                          # untriaged, classified below
        [pscustomobject]@{ number=11; url='https://x/11'; labels=@(@{name='type:bug'}) }          # already triaged
        [pscustomobject]@{ number=12; url='https://x/12'; labels=@() }                            # untriaged, NOT classified (dry-run)
    )
    $triages = @{ '10' = @{ type='bug'; priority='P1'; estimate='M'; risk='low'; area='core'; recommended_platform='Codex'; confidence=0.9 } }
    $plan = Build-SyncPlan -Issues $issues -Triages $triages -FieldMap $fieldMap -ClassifyWorkers @{ '12'='haiku' }
    $p10 = $plan | Where-Object { $_.number -eq 10 }
    Check 'T14 classified issue adds type:bug' ($p10.add_labels -contains 'type:bug')
    Check 'T15 classified issue sets Priority field' (@($p10.set_fields | Where-Object { $_.field -eq 'Priority' -and $_.option_id -eq 'o1' }).Count -eq 1)
    Check 'T16 classified issue queued for add_to_project' ($p10.add_to_project)
    $p11 = $plan | Where-Object { $_.number -eq 11 }
    Check 'T17 already-triaged issue not reclassified' (@($p11.add_labels).Count -eq 0 -and ($p11.skips -join ' ') -match 'already triaged')
    $p12 = $plan | Where-Object { $_.number -eq 12 }
    Check 'T18 untriaged-undispatched shows would-be worker' ($p12.classify_worker -eq 'haiku')

    # field absent in map -> skip with reason
    $plan2 = Build-SyncPlan -Issues @($issues[0]) -Triages $triages -FieldMap @{}
    $sk = ($plan2 | Where-Object { $_.number -eq 10 }).skips -join ' '
    Check 'T19 absent field -> skip reason' ($sk -match "field 'Priority' not found")

    # idempotent: label already present -> skip
    $issDup = @([pscustomobject]@{ number=13; url='u'; labels=@(@{name='type:bug'}, @{name='risk:low'}, @{name='area:core'}, @{name='estimate:M'}, @{name='route:Codex'}) })
    $triDup = @{ '13' = @{ type='bug'; priority='P1'; estimate='M'; risk='low'; area='core'; recommended_platform='Codex'; confidence=0.9 } }
    # treat as untriaged input by removing type:* so the planner computes desired labels, but they already exist:
    $issDup[0].labels = @(@{name='risk:low'}, @{name='area:core'}, @{name='estimate:M'}, @{name='route:Codex'})
    $pDup = Build-SyncPlan -Issues $issDup -Triages $triDup -FieldMap $fieldMap
    $pd = $pDup | Where-Object { $_.number -eq 13 }
    Check 'T20 present label -> skip not re-added' (($pd.add_labels -contains 'type:bug') -and -not ($pd.add_labels -contains 'risk:low'))

    # field already-correct -> skip
    $pCur = Build-SyncPlan -Issues @($issues[0]) -Triages $triages -FieldMap $fieldMap -CurrentFields @{ '10'=@{ Priority='P1' } }
    $pc = $pCur | Where-Object { $_.number -eq 10 }
    Check 'T21 already-correct field -> skip' ((($pc.skips -join ' ') -match "field 'Priority' already 'P1'") -and -not (@($pc.set_fields | Where-Object { $_.field -eq 'Priority' }).Count))

    # fallback -> needs-triage only, no fields
    $triFb = @{ '10' = @{ type='unknown'; priority='P3'; confidence=0.4 } }
    $pFb = (Build-SyncPlan -Issues @($issues[0]) -Triages $triFb -FieldMap $fieldMap) | Where-Object { $_.number -eq 10 }
    Check 'T22 fallback -> needs-triage label, no fields' (($pFb.add_labels -contains 'needs-triage') -and (@($pFb.set_fields).Count -eq 0))
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: FAIL — `Build-SyncPlan` not defined.

- [ ] **Step 3: Implement Build-SyncPlan**

Append to `scripts/projects-lib.ps1`:

```powershell
function Build-SyncPlan {
    # PURE (no gh): issues + per-issue triage + field map -> ordered per-issue plan.
    # Each already-present label / already-correct field / absent field becomes a skip.
    param(
        [Parameter(Mandatory)][object[]]$Issues,
        [hashtable]$Triages = @{},           # "<number>" -> triage hashtable
        [hashtable]$FieldMap = @{},           # field name -> @{ id; type; options{ name->id } }
        [hashtable]$CurrentFields = @{},      # "<number>" -> @{ fieldName -> currentValue }
        [hashtable]$ProjectItemNumbers = @{}, # "<number>" -> $true if already on project
        [hashtable]$ClassifyWorkers = @{}     # "<number>" -> worker name (dry-run peek)
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: ALL CHECKS PASS (T1–T22).

- [ ] **Step 5: Commit**

```bash
git add scripts/projects-lib.ps1 scripts/test-projects.ps1
git commit -m "feat(projects): pure Build-SyncPlan with idempotent skips (Sprint 3 Task 2)"
```

---

### Task 3: gh I/O layer (resolve / ensure / list / auth) with $GhInvoker seam

**Files:**
- Modify: `scripts/projects-lib.ps1` (append)
- Test: `scripts/test-projects.ps1` (append before `finally`)

- [ ] **Step 1: Write the failing tests**

Insert into `scripts/test-projects.ps1` before the `finally`:

```powershell
    # ---- Task 3: gh I/O (stubbed gh) ----
    # Stub gh: dispatches on argv[0..1]. Returns canned JSON; records mutating calls.
    $script:ghCalls = @()
    $ghStub = {
        param($argv)
        $script:ghCalls += ,(@($argv))
        $global:LASTEXITCODE = 0
        $join = ($argv -join ' ')
        if ($join -like 'auth status*') { return }
        if ($join -like 'project field-list*') {
            return '{"fields":[{"id":"PF_sta","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"oT","name":"Todo"},{"id":"oP","name":"In Progress"}]},{"id":"PF_pri","name":"Priority","type":"ProjectV2SingleSelectField","options":[{"id":"o1","name":"P1"}]}]}'
        }
        if ($join -like 'project field-create*') { return '{"id":"PF_new"}' }
        if ($join -like 'project item-list*') {
            return '{"items":[{"id":"IT_11","content":{"type":"Issue","number":11},"status":"Todo","priority":"P2"}]}'
        }
        if ($join -like 'issue list*') {
            return '[{"number":11,"title":"t","body":"b","url":"https://x/11","labels":[{"name":"type:bug"}],"assignees":[]}]'
        }
        return ''
    }

    Check 'T23 Test-GhAuth true when authed' (Test-GhAuth -GhInvoker $ghStub)
    $ghUnauth = { param($argv) $global:LASTEXITCODE = 1 }
    Check 'T24 Test-GhAuth false when unauth' (-not (Test-GhAuth -GhInvoker $ghUnauth))

    $fm = Resolve-ProjectFields -Owner '@me' -ProjectNumber 7 -GhInvoker $ghStub
    Check 'T25 Resolve-ProjectFields maps Priority option id' ($fm['Priority'].options['P1'] -eq 'o1')
    Check 'T26 Resolve-ProjectFields maps Status field id' ($fm['Status'].id -eq 'PF_sta')

    # Ensure: Priority present -> no field-create emitted
    $script:ghCalls = @()
    Ensure-ProjectFields -Owner '@me' -ProjectNumber 7 -FieldMap $fm -GhInvoker $ghStub | Out-Null
    Check 'T27 Ensure no-op when Priority present' (-not (@($script:ghCalls | Where-Object { ($_ -join ' ') -like 'project field-create*' }).Count))

    # Ensure: Priority absent -> field-create with P0..P4
    $script:ghCalls = @()
    Ensure-ProjectFields -Owner '@me' -ProjectNumber 7 -FieldMap @{ Status=@{id='PF_sta';options=@{Todo='oT'}} } -GhInvoker $ghStub | Out-Null
    $cre = @($script:ghCalls | Where-Object { ($_ -join ' ') -like 'project field-create*' })
    Check 'T28 Ensure creates Priority with options' (@($cre).Count -eq 1 -and (($cre[0] -join ' ') -match 'P0,P1,P2,P3,P4'))

    $items = Resolve-ProjectItems -Owner '@me' -ProjectNumber 7 -GhInvoker $ghStub
    Check 'T29 Resolve-ProjectItems maps number->item id' ($items['11'].item_id -eq 'IT_11')
    Check 'T30 Resolve-ProjectItems captures current field' ($items['11'].fields['Priority'] -eq 'P2')

    $iss = Get-RepoIssues -GhInvoker $ghStub
    Check 'T31 Get-RepoIssues returns parsed issues' (@($iss).Count -eq 1 -and $iss[0].number -eq 11)
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: FAIL — `Test-GhAuth` etc. not defined.

- [ ] **Step 3: Implement the I/O layer**

Append to `scripts/projects-lib.ps1`:

```powershell
function Test-GhAuth {
    # Preflight: is gh authenticated? Default invoker shells real gh and sets $LASTEXITCODE.
    param([scriptblock]$GhInvoker = { param($argv) & gh @argv })
    try { & $GhInvoker @('auth','status') *> $null; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}

function Get-RepoIssues {
    # Open issues with the fields the planner needs.
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
    # gh project field-list -> @{ name -> @{ id; type; options{ name->id } } }. Read-only.
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
    # Create the Priority single-select if absent (idempotent). Returns refreshed field map.
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
    # gh project item-list -> @{ "<issue-number>" -> @{ item_id; fields{ FieldName->value } } }.
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: ALL CHECKS PASS (T1–T31).

- [ ] **Step 5: Commit**

```bash
git add scripts/projects-lib.ps1 scripts/test-projects.ps1
git commit -m "feat(projects): gh I/O layer (resolve/ensure/list/auth) behind GhInvoker seam (Sprint 3 Task 3)"
```

---

### Task 4: Invoke-SyncPlan (apply, best-effort)

**Files:**
- Modify: `scripts/projects-lib.ps1` (append)
- Test: `scripts/test-projects.ps1` (append before `finally`)

- [ ] **Step 1: Write the failing tests**

Insert into `scripts/test-projects.ps1` before the `finally`:

```powershell
    # ---- Task 4: Invoke-SyncPlan (apply, stubbed gh) ----
    $script:applyCalls = @()
    $applyStub = {
        param($argv)
        $script:applyCalls += ,(@($argv))
        $global:LASTEXITCODE = 0
        if (($argv -join ' ') -like 'project item-add*') { return '{"id":"IT_NEW"}' }
        return ''
    }
    $applyPlan = @(
        [pscustomobject]@{ number=20; url='https://x/20'; add_labels=@('type:bug','route:Codex'); add_to_project=$true
                           set_fields=@(@{ field='Priority'; field_id='PF_pri'; value='P1'; option_id='o1' }); skips=@() }
    )
    $res = Invoke-SyncPlan -Plan $applyPlan -Owner '@me' -ProjectNumber 7 -ProjectId 'PVT_x' -GhInvoker $applyStub
    Check 'T32 apply edits labels' (@($script:applyCalls | Where-Object { ($_ -join ' ') -match 'issue edit 20.*--add-label type:bug' }).Count -eq 1)
    Check 'T33 apply adds item to project' (@($script:applyCalls | Where-Object { ($_ -join ' ') -like 'project item-add 7*' }).Count -eq 1)
    Check 'T34 apply edits field with new item id' (@($script:applyCalls | Where-Object { ($_ -join ' ') -match 'item-edit .*--id IT_NEW.*--single-select-option-id o1' }).Count -eq 1)
    Check 'T35 apply records success' (@($res[0].applied).Count -ge 3 -and -not $res[0].error)

    # best-effort: a failing label edit is recorded but the batch continues
    $script:applyCalls = @()
    $failStub = {
        param($argv)
        $script:applyCalls += ,(@($argv))
        if (($argv -join ' ') -like 'issue edit 30*') { $global:LASTEXITCODE = 1; return }
        $global:LASTEXITCODE = 0
        if (($argv -join ' ') -like 'project item-add*') { return '{"id":"IT_X"}' }
        return ''
    }
    $plan2 = @(
        [pscustomobject]@{ number=30; url='u30'; add_labels=@('type:bug'); add_to_project=$false; set_fields=@(); skips=@() }
        [pscustomobject]@{ number=31; url='u31'; add_labels=@('type:docs'); add_to_project=$false; set_fields=@(); skips=@() }
    )
    $res2 = Invoke-SyncPlan -Plan $plan2 -Owner '@me' -ProjectNumber 7 -ProjectId 'PVT_x' -GhInvoker $failStub
    $r30 = $res2 | Where-Object { $_.number -eq 30 }
    $r31 = $res2 | Where-Object { $_.number -eq 31 }
    Check 'T36 failing issue recorded in failed' (@($r30.failed).Count -ge 1)
    Check 'T37 batch continues after a failure' (@($r31.applied | Where-Object { $_ -like 'labels:*' }).Count -eq 1)
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: FAIL — `Invoke-SyncPlan` not defined.

- [ ] **Step 3: Implement Invoke-SyncPlan**

Append to `scripts/projects-lib.ps1`:

```powershell
function Invoke-SyncPlan {
    # APPLY: execute a plan via gh. Best-effort per issue — one failure never aborts the batch.
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][int]$ProjectNumber,
        [string]$ProjectId, [string]$Repo,
        [hashtable]$ProjectItemIds = @{},   # "<number>" -> existing item id (for issues already on the board)
        [scriptblock]$GhInvoker = { param($argv) & gh @argv }
    )
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Plan)) {
        $num = [int]$entry.number
        $applied = @(); $failed = @(); $err = $null
        $itemId = if ($ProjectItemIds.ContainsKey("$num")) { [string]$ProjectItemIds["$num"] } else { $null }
        try {
            if (@($entry.add_labels).Count -gt 0) {
                $argv = @('issue','edit',"$num")
                foreach ($l in @($entry.add_labels)) { $argv += @('--add-label',$l) }
                if ($Repo) { $argv += @('--repo',$Repo) }
                & $GhInvoker $argv | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "gh issue edit failed for #$num" }
                $applied += "labels: $($entry.add_labels -join ',')"
            }
            if ($entry.add_to_project) {
                $argv = @('project','item-add',"$ProjectNumber",'--owner',$Owner,'--format','json')
                if ($entry.url) { $argv += @('--url',[string]$entry.url) }
                $out = & $GhInvoker $argv
                if ($LASTEXITCODE -ne 0) { throw "gh project item-add failed for #$num" }
                $applied += "added to project"
                $j = ($out | Out-String).Trim()
                if ($j) { try { $itemId = [string]($j | ConvertFrom-Json).id } catch {} }
            }
            foreach ($sf in @($entry.set_fields)) {
                if (-not $itemId) { $failed += "field $($sf.field): no item id"; continue }
                $argv = @('project','item-edit','--id',$itemId,'--project-id',$ProjectId,'--field-id',[string]$sf.field_id,'--single-select-option-id',[string]$sf.option_id)
                & $GhInvoker $argv | Out-Null
                if ($LASTEXITCODE -ne 0) { $failed += "field $($sf.field) edit failed"; continue }
                $applied += "field $($sf.field)=$($sf.value)"
            }
        } catch { $err = "$_"; $failed += $err }
        $results.Add([pscustomobject]@{ number=$num; applied=$applied; failed=$failed; error=$err })
    }
    return ,([object[]]$results.ToArray())
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: ALL CHECKS PASS (T1–T37).

- [ ] **Step 5: Commit**

```bash
git add scripts/projects-lib.ps1 scripts/test-projects.ps1
git commit -m "feat(projects): Invoke-SyncPlan apply path, best-effort per issue (Sprint 3 Task 4)"
```

---

### Task 5: CLI (`fleet-projects.ps1`) + slash command + CLI tests

**Files:**
- Create: `scripts/fleet-projects.ps1`
- Create: `commands/projects.md`
- Test: `scripts/test-projects.ps1` (append before `finally`)

- [ ] **Step 1: Write the failing CLI tests**

Insert into `scripts/test-projects.ps1` before the `finally`:

```powershell
    # ---- Task 5: CLI (child-process so its exit never aborts this suite) ----
    $cli = Join-Path $PSScriptRoot 'fleet-projects.ps1'
    Check 'T38 CLI file exists' (Test-Path $cli)

    # dry-run sync against a stub gh injected via env: must emit ZERO mutating gh calls.
    # The CLI honors $env:BATON_PROJECTS_TEST_GH (a file of newline argv records it appends to).
    $callLog = Join-Path $tmpDir 'ghcalls.txt'
    $env:BATON_PROJECTS_TEST_GH = $callLog
    if (Test-Path $callLog) { Remove-Item $callLog -Force }
    & pwsh -NoProfile -File $cli 'sync' '--owner' '@me' '--project' '7' *> $null
    $dryOk = $true
    if (Test-Path $callLog) {
        $mut = Get-Content $callLog | Where-Object { $_ -match 'issue edit|item-add|item-edit|field-create' }
        $dryOk = (@($mut).Count -eq 0)
    }
    Check 'T39 dry-run emits zero mutating gh calls' $dryOk
    Remove-Item Env:\BATON_PROJECTS_TEST_GH -ErrorAction SilentlyContinue
```

Add a `$tmpDir` at the top of the `try` (if not already present) — insert right after `. "$PSScriptRoot/projects-lib.ps1"` is loaded, at the very start of the `try` block:

```powershell
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("proj-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
```

And in the `finally`, before the pass/fail summary, clean it up:

```powershell
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: FAIL — `fleet-projects.ps1` does not exist (T38).

- [ ] **Step 3: Implement the CLI**

Create `scripts/fleet-projects.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:projects runner. Syncs Triage classification to GitHub as labels (classify)
  + Project v2 fields (decide). Dry-run by default; --apply commits. All GitHub ops go
  through gh. A test seam ($env:BATON_PROJECTS_TEST_GH) records gh argv to a file and
  returns canned JSON so the suite never touches a real repo/board.
.USAGE
  fleet-projects.ps1 init  --owner @me [--repo O/R] [--title "Baton Board"]
  fleet-projects.ps1 sync  --owner @me --project N [--repo O/R] [--apply] [--reclassify] [--classify] [--json]
#>
param(
    [Parameter(Position=0)][ValidateSet('init','sync')][string]$Command = 'sync',
    [string]$Owner = '@me',
    [string]$Repo,
    [int]$Project,
    [string]$Title = 'Baton Board',
    [switch]$Apply,
    [switch]$Reclassify,
    [switch]$Classify,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/projects-lib.ps1"
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"
. "$PSScriptRoot/triage-lib.ps1"

# Test seam: when set, a stub gh that logs argv and returns canned JSON. No real gh.
$ghInvoker = { param($argv) & gh @argv }
if ($env:BATON_PROJECTS_TEST_GH) {
    $logPath = $env:BATON_PROJECTS_TEST_GH
    $ghInvoker = {
        param($argv)
        Add-Content -LiteralPath $logPath -Value ($argv -join ' ') -Encoding utf8
        $global:LASTEXITCODE = 0
        $j = ($argv -join ' ')
        if ($j -like 'auth status*')          { return }
        if ($j -like 'project field-list*')   { return '{"fields":[{"id":"PF_sta","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"oT","name":"Todo"}]},{"id":"PF_pri","name":"Priority","type":"ProjectV2SingleSelectField","options":[{"id":"o1","name":"P1"}]}]}' }
        if ($j -like 'project item-list*')     { return '{"items":[]}' }
        if ($j -like 'issue list*')            { return '[{"number":11,"title":"t","body":"b","url":"https://x/11","labels":[],"assignees":[]}]' }
        return ''
    }
}

if (-not (Test-GhAuth -GhInvoker $ghInvoker)) {
    Write-Error "gh is not authenticated. Run 'gh auth login' first."
    exit 3
}

if ($Command -eq 'init') {
    $argv = @('project','create','--owner',$Owner,'--title',$Title,'--format','json')
    $out = & $ghInvoker $argv
    if ($LASTEXITCODE -ne 0) { Write-Error "gh project create failed"; exit 2 }
    $num = $null
    try { $num = [int](($out | Out-String).Trim() | ConvertFrom-Json).number } catch {}
    if ($num) {
        Ensure-ProjectFields -Owner $Owner -ProjectNumber $num -FieldMap (Resolve-ProjectFields -Owner $Owner -ProjectNumber $num -GhInvoker $ghInvoker) -GhInvoker $ghInvoker | Out-Null
        Write-Host "Created project #$num and ensured Priority field."
    } else {
        Write-Host "Project created (number unparsed)."
    }
    exit 0
}

# ---- sync ----
if (-not $Project) { Write-Error "sync requires --project N (run 'projects init' first)."; exit 2 }

$issues = Get-RepoIssues -Repo $Repo -GhInvoker $ghInvoker
$fieldMap = Resolve-ProjectFields -Owner $Owner -ProjectNumber $Project -GhInvoker $ghInvoker
if ($Apply) { $fieldMap = Ensure-ProjectFields -Owner $Owner -ProjectNumber $Project -FieldMap $fieldMap -GhInvoker $ghInvoker }
$itemMap = Resolve-ProjectItems -Owner $Owner -ProjectNumber $Project -GhInvoker $ghInvoker
$existingNums = @{}; $itemIds = @{}; $curFields = @{}
foreach ($k in $itemMap.Keys) { $existingNums[$k] = $true; $itemIds[$k] = $itemMap[$k].item_id; $curFields[$k] = $itemMap[$k].fields }

# Peek the would-be classifier once (read-only) for dry-run legibility.
$peekWorker = '(none available)'
try {
    $cands = Select-Capability -Capability triage -MaxCostTier paid
    if ($cands -and @($cands).Count -gt 0) { $peekWorker = [string]$cands[0].name }
} catch {}

$triages = @{}; $classifyWorkers = @{}
foreach ($iss in @($issues)) {
    $key = "$([int]$iss.number)"
    $state = Get-IssueTriageState -Issue $iss
    if ($state.triaged -and -not $Reclassify) { continue }
    if (-not $state.triaged -or $Reclassify) {
        if ($Apply -or $Classify) {
            $text = "$($iss.title)`n`n$($iss.body)"
            $triages[$key] = Invoke-TriageAgent -Input $text
        } else {
            $classifyWorkers[$key] = $peekWorker   # dry-run, no token spend
        }
    }
}

$plan = Build-SyncPlan -Issues $issues -Triages $triages -FieldMap $fieldMap `
        -CurrentFields $curFields -ProjectItemNumbers $existingNums -ClassifyWorkers $classifyWorkers

if ($Json) { $plan | ConvertTo-Json -Depth 8; exit 0 }

if (-not $Apply) {
    Write-Host "PLAN (dry-run — no writes):"
    foreach ($e in @($plan)) {
        $parts = @()
        if (@($e.add_labels).Count) { $parts += "add $($e.add_labels -join ', ')" }
        if (@($e.set_fields).Count) { $parts += "set $((@($e.set_fields | ForEach-Object { "$($_.field)=$($_.value)" }) -join ', '))" }
        if ($e.add_to_project)      { $parts += "+add to project" }
        if ($e.classify_worker)     { $parts += "would classify via $($e.classify_worker)" }
        $line = if ($parts.Count) { $parts -join '; ' } else { ($e.skips -join '; ') }
        Write-Host ("  #{0}  {1}" -f $e.number, $line)
    }
    Write-Host "Re-run with --apply to write."
    exit 0
}

$results = Invoke-SyncPlan -Plan $plan -Owner $Owner -ProjectNumber $Project -ProjectId $itemMap['__project_id__'] -Repo $Repo -ProjectItemIds $itemIds -GhInvoker $ghInvoker
foreach ($r in @($results)) {
    $msg = if ($r.error) { "ERROR $($r.error)" } elseif (@($r.failed).Count) { "partial — $($r.applied -join ', ') | failed: $($r.failed -join ', ')" } else { ($r.applied -join ', ') }
    Write-Host ("  #{0}  {1}" -f $r.number, $msg)
}
```

> **Implementer note on `ProjectId`:** `gh project item-edit` needs the project node id. Resolve it once in `sync` from `gh project view <num> --owner <o> --format json` (`.id`) and pass it to `Invoke-SyncPlan -ProjectId`. Add a `Resolve-ProjectId` helper to `projects-lib.ps1` mirroring `Resolve-ProjectFields` (argv `@('project','view',"$ProjectNumber",'--owner',$Owner,'--format','json')`, return `(... | ConvertFrom-Json).id`), call it in the `sync` apply branch, and replace `$itemMap['__project_id__']` with that value. Keep the dry-run path free of this call (no need when not writing).

- [ ] **Step 2b: Add the `Resolve-ProjectId` helper**

Append to `scripts/projects-lib.ps1`:

```powershell
function Resolve-ProjectId {
    # Project node id (needed by item-edit). Read-only.
    param(
        [Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][int]$ProjectNumber,
        [scriptblock]$GhInvoker = { param($argv) & gh @argv }
    )
    $argv = @('project','view',"$ProjectNumber",'--owner',$Owner,'--format','json')
    $json = ((& $GhInvoker $argv) | Out-String).Trim()
    if (-not $json) { return $null }
    return [string]($json | ConvertFrom-Json).id
}
```

And in `fleet-projects.ps1` replace the final `Invoke-SyncPlan` line's `-ProjectId $itemMap['__project_id__']` with:

```powershell
$projectId = Resolve-ProjectId -Owner $Owner -ProjectNumber $Project -GhInvoker $ghInvoker
$results = Invoke-SyncPlan -Plan $plan -Owner $Owner -ProjectNumber $Project -ProjectId $projectId -Repo $Repo -ProjectItemIds $itemIds -GhInvoker $ghInvoker
```

- [ ] **Step 3: Create the slash command**

Create `commands/projects.md`:

```markdown
---
description: Sync Triage classification to GitHub — labels (classify) + Project v2 fields (decide). Dry-run by default.
argument-hint: "[init|sync] --owner @me --project N [--apply] [--reclassify] [--classify] [--json]"
---

# /baton:projects

Pulls open issues, classifies the untriaged ones through the Triage Agent, and writes
the result back as **labels** (`type:`/`area:`/`risk:`/`estimate:`/`route:`) and
**Project v2 fields** (`Priority`, `Status`). Dry-run by default — nothing is written
until you re-run with `--apply`. All GitHub operations go through `gh`.

## Steps

1. Run the runner with the user's arguments:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-projects.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `init --owner @me --title "Baton Board"` — one-time: create the Project + ensure the Priority field.
   - `sync --owner @me --project 7` — dry-run: print the planned label/field writes and the would-be classifier per untriaged issue (zero token spend).
   - `sync --owner @me --project 7 --apply` — classify untriaged issues (governed routing) and write labels + fields.
   - `--reclassify` re-runs triage on already-typed issues; `--classify` classifies during dry-run; `--json` emits the raw plan.

3. Summarize the plan/results in plain language: which issues got which labels/fields,
   which were skipped (already correct), and which worker classified them.
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-projects.ps1`
Expected: ALL CHECKS PASS (T1–T39).

- [ ] **Step 5: Commit**

```bash
git add scripts/projects-lib.ps1 scripts/fleet-projects.ps1 commands/projects.md scripts/test-projects.ps1
git commit -m "feat(projects): /baton:projects CLI (init + dry-run/apply sync) (Sprint 3 Task 5)"
```

---

### Task 6: Deploy wiring + full gate + final review

**Files:**
- Modify: `scripts/bootstrap.ps1:259` (manifest array)
- Modify: `scripts/test-bootstrap.ps1`
- Modify: `.claude-plugin/plugin.json` (version)

- [ ] **Step 1: Add the deploy assertions (failing)**

In `scripts/test-bootstrap.ps1`, find the block of `Assert "deploys <x> script" ($out -match '<x>\.ps1')` lines (near the usage-lib / fleet-usage assertions) and add after them:

```powershell
Assert "deploys projects-lib script" ($out -match 'projects-lib\.ps1')
Assert "deploys fleet-projects script" ($out -match 'fleet-projects\.ps1')
```

> Match the EXACT existing assertion idiom in the file (it uses `$out -match`). If the surrounding assertions use a different variable or matcher, mirror that instead — do not introduce a new style.

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — the two new scripts are not in the manifest yet.

- [ ] **Step 3: Add the scripts to the bootstrap manifest**

In `scripts/bootstrap.ps1` line 259, in the `foreach ($script in @(...))` manifest array, add `'projects-lib.ps1', 'fleet-projects.ps1'` immediately after `'fleet-usage.ps1'`:

```powershell
... 'usage-lib.ps1', 'fleet-usage.ps1', 'projects-lib.ps1', 'fleet-projects.ps1', 'idea-lib.ps1')) {
```

- [ ] **Step 4: Bump the plugin version**

In `.claude-plugin/plugin.json`, change `"version": "1.2.0-rc.9"` to `"version": "1.2.0-rc.10"`.

- [ ] **Step 5: Run the full gate**

```bash
pwsh -NoProfile -File scripts/test-projects.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
pwsh -NoProfile -File scripts/test-routing-lib.ps1
```

Expected: all three suites pass (projects T1–T39; bootstrap incl. the two new asserts; routing-lib unaffected). If `test-routing-lib.ps1` or any routing suite is touched by the new `routing-lib.ps1` dot-source in the CLI, it should NOT be — the CLI sources routing-lib but the suites don't load the CLI. Confirm green.

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "feat(projects): deploy projects scripts via bootstrap; bump to rc.10 (Sprint 3 Task 6)"
```

- [ ] **Step 7: Final adversarial review**

Dispatch ONE comprehensive code reviewer over the whole branch diff (per the operator's execution-style preference: skip per-task reviewers, do one final adversarial pass). Focus areas:
1. **gh arg correctness** — do the emitted `gh project field-create` / `item-edit` / `item-add` / `issue edit` arg arrays match gh 2.86.0's actual flags? (`--single-select-option-id`, `--field-id`, `--project-id`, `--id` for item-edit; `--data-type SINGLE_SELECT --single-select-options` for field-create.)
2. **No real gh/model/repo touched in any test** — every gh call stubbed; triage stubbed; no `~/.baton` or network.
3. **Array-flatten traps** — `,([object[]])` returns not re-wrapped in `@()` at call sites.
4. **Dry-run truly zero-spend** — no `Invoke-TriageAgent` and no mutating gh call on the dry-run path.
5. **Idempotency** — re-running sync adds nothing already present.
6. **Box-private** — no real owner/repo/project number committed anywhere; seed/examples use placeholders.

Fix any blocking findings; leave documented cosmetic nits.

---

## Self-Review (completed during planning)

- **Spec coverage:** every spec section maps to a task — pure mapping (§3 → T1), planner (§5 → T2), I/O + ensure-structure (§4 → T3), apply (§4/§6 → T4), CLI init+sync+dry-run-zero-spend (§5/§7 → T5), deploy + tests + version (§4 → T6). ✓
- **Placeholder scan:** no TBD/TODO; all code shown in full. ✓
- **Type consistency:** `Build-SyncPlan` emits `set_fields` items `@{field;field_id;value;option_id}`; `Invoke-SyncPlan` reads exactly those keys; `Resolve-ProjectFields` emits `@{id;type;options}` consumed by the planner; `Resolve-ProjectItems` emits `@{item_id;fields}` consumed by the CLI. ✓
- **Known traps avoided:** no `-Input`/`-Event` params; child-process CLI test (T39) so the CLI's `exit` can't abort the suite (Sprint 2 N1 lesson); `$LASTEXITCODE` set inside stubs.
