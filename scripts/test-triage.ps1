#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/triage-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tri-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Stub fleet used across the suite: two paid triage providers + one unrelated.
$stubFleet = @"
general_capabilities: [code-gen, reasoning, summarize]

providers:
  - name: claude-haiku
    kind: cli
    enabled: true
    cost_tier: paid
    stdin: true
    capabilities: [triage, classify, summarize-short]
    model_default: 'claude-haiku-4-5-20251001'
    command_template: 'claude -p --model claude-haiku-4-5-20251001'
  - name: claude-sonnet
    kind: cli
    enabled: true
    cost_tier: paid
    stdin: true
    capabilities: [triage, code-gen, reasoning, summarize]
    model_default: 'claude-sonnet-4-6'
    command_template: 'claude -p --model claude-sonnet-4-6'
  - name: claude-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'claude -p "{{prompt}}"'
"@
$stubFleetPath = Join-Path $tmp 'fleet.yaml'
Set-Content -Path $stubFleetPath -Value $stubFleet -Encoding utf8

try {
    # T11: the repo seed fleet.yaml carries a claude-haiku entry claiming triage.
    # The deployable seed is references/fleet.yaml (bootstrap copies it to BATON_HOME).
    $repoFleet = Get-Content (Join-Path $PSScriptRoot '..' 'references' 'fleet.yaml') -Raw
    Check 'T11 seed fleet.yaml has claude-haiku triage provider' `
        ($repoFleet -match 'name:\s*claude-haiku' -and $repoFleet -match 'triage')

    # T12: Select-Capability triage returns claude-haiku first (cheapest capable)
    $cands = Select-Capability -Capability triage -FleetPath $stubFleetPath -ToolsPath (Join-Path $tmp 'no-tools.yaml')
    Check 'T12 Select-Capability triage -> claude-haiku first' `
        (@($cands).Count -ge 1 -and $cands[0].name -eq 'claude-haiku')

    # T1: --Text passthrough
    Check 'T1 Read-TriageInput text passthrough' `
        ((Read-TriageInput -Text 'Add retry logic') -eq 'Add retry logic')

    # T2: --File reads content
    $taskFile = Join-Path $tmp 'task.md'
    Set-Content -Path $taskFile -Value "# Fix the parser`nIt drops quoted commas." -Encoding utf8
    $fromFile = Read-TriageInput -File $taskFile
    Check 'T2 Read-TriageInput file read' `
        ($fromFile -match 'Fix the parser' -and $fromFile -match 'quoted commas')

    # Read-TriageInput requires exactly one source
    $threw = $false
    try { Read-TriageInput } catch { $threw = $true }
    Check 'T2b Read-TriageInput with no source throws' $threw

    # T3: prompt embeds the task text and the JSON schema contract
    $prompt = Build-TriagePrompt -TaskText 'Add retry logic to dispatch'
    Check 'T3a prompt contains the task text'  ($prompt -match 'Add retry logic to dispatch')
    Check 'T3b prompt contains the schema key' ($prompt -match '"confidence"' -and $prompt -match '"recommended_model"')
    Check 'T3c prompt demands JSON-only'       ($prompt -match 'ONLY valid JSON')
