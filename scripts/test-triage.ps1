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

    # T4: low confidence escalates
    Check 'T4 escalate when confidence 0.65' `
        (Test-TriageEscalationNeeded -Triage @{ confidence = 0.65; risk = 'low'; ambiguity = 'low' })

    # T5: confident + medium risk does NOT escalate
    Check 'T5 no escalate at conf 0.85 risk medium' `
        (-not (Test-TriageEscalationNeeded -Triage @{ confidence = 0.85; risk = 'medium'; ambiguity = 'low' }))

    # T6: high risk escalates regardless of confidence
    Check 'T6 escalate when risk high' `
        (Test-TriageEscalationNeeded -Triage @{ confidence = 0.99; risk = 'high'; ambiguity = 'low' })

    # T6b: high ambiguity escalates
    Check 'T6b escalate when ambiguity high' `
        (Test-TriageEscalationNeeded -Triage @{ confidence = 0.99; risk = 'low'; ambiguity = 'high' })

    # T6c: Get-TriageJsonBlock extracts the JSON object from a fenced/prose reply
    $fenced = @'
Here you go:
```json
{ "type": "bug" }
```
'@
    Check 'T6c Get-TriageJsonBlock extracts JSON from fenced reply' `
        ((Get-TriageJsonBlock -Raw $fenced).Trim() -match '^\{\s*"type"\s*:\s*"bug"\s*\}$')

    # A dispatcher that returns canned JSON keyed by provider name.
    $goodJson = '{ "type":"plan","priority":"P2","estimate":"S","risk":"medium","research_required":false,"recommended_platform":"Claude","recommended_model":"Sonnet","agent_type":"Planning","pipeline":["spec_review","implementation_plan","review"],"area":"registry","next_action":"Write the plan.","confidence":0.84,"ambiguity":"low" }'
    $dispGood = { param($cand,$prompt) @{ stdout = $goodJson; stderr=''; exit_code = 0; duration_s = 1 } }

    # T7: clean JSON -> parsed triage hashtable, no escalation
    $t7 = Invoke-TriageAgent -Input 'Plan the registry work' -FleetPath $stubFleetPath -ToolsPath (Join-Path $tmp 'no-tools.yaml') -Dispatcher $dispGood
    Check 'T7a parses type'        ($t7.type -eq 'plan')
    Check 'T7b parses confidence'  ([double]$t7.confidence -eq 0.84)
    Check 'T7c not escalated'      (-not $t7.escalated)

    # T8: malformed JSON -> deterministic fallback
    $dispBad = { param($cand,$prompt) @{ stdout = 'sorry, I cannot do that'; stderr=''; exit_code = 0; duration_s = 1 } }
    $t8 = Invoke-TriageAgent -Input 'whatever' -FleetPath $stubFleetPath -ToolsPath (Join-Path $tmp 'no-tools.yaml') -Dispatcher $dispBad
    Check 'T8a fallback type unknown'  ($t8.type -eq 'unknown')
    Check 'T8b fallback confidence'    ([double]$t8.confidence -eq 0.40)
    Check 'T8c fallback escalation flag'($t8.escalation_needed -eq $true)

    # T9: no candidates -> deterministic fallback
    $emptyFleet = Join-Path $tmp 'empty-fleet.yaml'
    Set-Content -Path $emptyFleet -Value "providers:`n  - name: nobody`n    kind: cli`n    enabled: false`n    cost_tier: paid" -Encoding utf8
    $t9 = Invoke-TriageAgent -Input 'x' -FleetPath $emptyFleet -ToolsPath (Join-Path $tmp 'no-tools.yaml') -Dispatcher $dispGood
    Check 'T9 no-candidates fallback' ($t9.type -eq 'unknown' -and [double]$t9.confidence -eq 0.40)

    # T10: low-confidence first pass escalates to the OTHER candidate (Sonnet)
    $lowJson  = '{ "type":"bug","priority":"P1","estimate":"M","risk":"medium","research_required":false,"recommended_platform":"Claude","recommended_model":"Haiku","agent_type":"Triage","pipeline":["review"],"area":null,"next_action":"Look closer.","confidence":0.55,"ambiguity":"high" }'
    $highJson = '{ "type":"bug","priority":"P1","estimate":"M","risk":"medium","research_required":false,"recommended_platform":"Claude","recommended_model":"Sonnet","agent_type":"Planning","pipeline":["spec_review","review"],"area":"parser","next_action":"Add a failing test.","confidence":0.88,"ambiguity":"low" }'
    $dispEsc = { param($cand,$prompt) if ($cand.name -eq 'claude-haiku') { @{ stdout=$lowJson; stderr=''; exit_code=0; duration_s=1 } } else { @{ stdout=$highJson; stderr=''; exit_code=0; duration_s=1 } } }
    $t10 = Invoke-TriageAgent -Input 'ambiguous bug' -FleetPath $stubFleetPath -ToolsPath (Join-Path $tmp 'no-tools.yaml') -Dispatcher $dispEsc
    Check 'T10a escalated flag set'      ($t10.escalated -eq $true)
    Check 'T10b escalated_from haiku'    ($t10.escalated_from -eq 'claude-haiku')
    Check 'T10c authoritative = sonnet result' ([double]$t10.confidence -eq 0.88 -and $t10.area -eq 'parser')
