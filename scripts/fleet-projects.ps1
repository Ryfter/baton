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

$projectId = Resolve-ProjectId -Owner $Owner -ProjectNumber $Project -GhInvoker $ghInvoker
$results = Invoke-SyncPlan -Plan $plan -Owner $Owner -ProjectNumber $Project -ProjectId $projectId -Repo $Repo -ProjectItemIds $itemIds -GhInvoker $ghInvoker
foreach ($r in @($results)) {
    $msg = if ($r.error) { "ERROR $($r.error)" } elseif (@($r.failed).Count) { "partial — $($r.applied -join ', ') | failed: $($r.failed -join ', ')" } else { ($r.applied -join ', ') }
    Write-Host ("  #{0}  {1}" -f $r.number, $msg)
}
