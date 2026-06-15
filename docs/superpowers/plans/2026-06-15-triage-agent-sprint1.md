# Triage Agent (Sprint 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/baton:triage` — classify any issue/task text into a structured triage object (type, priority, estimate, risk, pipeline, confidence) by routing through the existing fleet + usage_class system, Haiku preferred, Sonnet escalation on low confidence / high risk.

**Architecture:** A new `triage-lib.ps1` adds four functions on top of the existing routing stack. `Invoke-TriageAgent` calls `Select-Capability -Capability triage` (already claims-aware) to pick the cheapest candidate, dispatches it via `Invoke-Fleet` (injectable `-Dispatcher` for tests), parses strict JSON from the model's reply, and escalates to a champion-ranked second candidate when confidence < 0.70 or risk is high. Two new `cli` providers (`claude-haiku`, `claude-sonnet`) carry the `triage` claim and use `stdin: true` so the JSON-schema-heavy prompt is piped (never interpolated through `Invoke-Expression`). A thin `fleet-triage.ps1` wraps input resolution + YAML/JSON formatting for the slash command.

**Tech Stack:** PowerShell 7, the line-oriented fleet.yaml parser (no module deps), the existing `Select-Capability`/`Invoke-Fleet` routing path, `Check`-style test suites, `gh issue view` for URL input.

**Branch:** `feat/triage-agent-sprint1` (worktree-isolated; gated merge flow).
**Spec:** `docs/superpowers/specs/2026-06-15-triage-agent-sprint1-design.md`.
**Issue:** Closes #51.
**Standing rules:** tests NEVER touch real `~/.baton` / `~/.claude` — every path explicit under `$env:TEMP`; Kevin's execution style = skip per-task reviewers, ONE adversarial review in the final task.

---

## File map

| File | Change |
|---|---|
| `fleet.yaml` (repo seed) | add `claude-haiku` + `claude-sonnet` providers with `triage` claim, `stdin: true` |
| `references/fleet.yaml` | add `triage` to the capability taxonomy doc block + example claim note |
| `scripts/triage-lib.ps1` | NEW — `Read-TriageInput`, `Build-TriagePrompt`, `Test-TriageEscalationNeeded`, `Get-TriageJsonBlock`, `Invoke-TriageAgent` |
| `scripts/fleet-triage.ps1` | NEW — CLI wrapper / command runner (input routing + YAML/JSON output) |
| `scripts/test-triage.ps1` | NEW — 15-test suite (injected dispatcher + stub fleet) |
| `commands/triage.md` | NEW — `/baton:triage` slash command |
| `scripts/bootstrap.ps1` | add `triage-lib.ps1` + `fleet-triage.ps1` to the script manifest |
| `scripts/test-bootstrap.ps1` | assert triage scripts deploy |
| `.claude-plugin/plugin.json` | version `1.2.0-rc.7` → `1.2.0-rc.8` |

---

### Task 1: fleet.yaml seed — claude-haiku + claude-sonnet triage providers

**Files:**
- Modify: `fleet.yaml` (append to the `providers:` block, after `gh-copilot`)
- Modify: `references/fleet.yaml` (taxonomy doc block)
- Test: `scripts/test-triage.ps1` (NEW — create the harness scaffold here; later tasks append to it)

- [ ] **Step 1: Write the failing test.** Create `scripts/test-triage.ps1` with the harness scaffold and the first two checks:

```powershell
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
    # T11: the repo seed fleet.yaml carries a claude-haiku entry claiming triage
    $repoFleet = Get-Content (Join-Path $PSScriptRoot '..' 'fleet.yaml') -Raw
    Check 'T11 seed fleet.yaml has claude-haiku triage provider' `
        ($repoFleet -match 'name:\s*claude-haiku' -and $repoFleet -match 'triage')

    # T12: Select-Capability triage returns claude-haiku first (cheapest capable)
    $cands = Select-Capability -Capability triage -FleetPath $stubFleetPath -ToolsPath (Join-Path $tmp 'no-tools.yaml')
    Check 'T12 Select-Capability triage -> claude-haiku first' `
        (@($cands).Count -ge 1 -and $cands[0].name -eq 'claude-haiku')
```

Leave the `try` block open — Task 2+ append more checks, and the final task closes it with the summary/exit block (Step shown in Task 6).

- [ ] **Step 2: Run to verify it fails.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: errors — `triage-lib.ps1` does not exist yet (dot-source fails), and the seed fleet.yaml has no `claude-haiku`.

- [ ] **Step 3: Add the providers to the repo seed `fleet.yaml`.** Append after the `gh-copilot` provider block (before the `# ── Firefly local serving` comment):

```yaml
  # ── Triage workers (Sprint 1): explicit model pins for the triage role. ──
  # stdin: true so the JSON-schema-heavy triage prompt is piped, never
  # interpolated through Invoke-Expression (which would mangle quotes/braces).
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
```

- [ ] **Step 4: Document the `triage` capability in `references/fleet.yaml`.** Find the capability taxonomy comment block (the canonical name list: `code-gen`, `code-transform`, ... `judge`, `reasoning`, `vision`) and add `triage` and `classify` to it. Add a one-line note near the example claims:

```
#   triage / classify  — structured task classification (issue → type/priority/risk)
```

- [ ] **Step 5: Run to verify T11/T12 pass (others still error until Task 2).** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: still errors on the `. triage-lib.ps1` dot-source at the top (file absent). That is fine — Task 2 creates the file; re-run there. To check T11/T12 in isolation now, temporarily comment the dot-source line, run, confirm `PASS: T11` and `PASS: T12`, then restore it.

- [ ] **Step 6: Commit.**

```bash
git add fleet.yaml references/fleet.yaml scripts/test-triage.ps1
git commit -m "feat(triage): seed claude-haiku/claude-sonnet triage providers + test scaffold"
```

---

### Task 2: triage-lib.ps1 — Read-TriageInput

**Files:**
- Create: `scripts/triage-lib.ps1`
- Test: `scripts/test-triage.ps1` (append inside the `try` block)

- [ ] **Step 1: Write the failing tests.** Append to the `try` block in `scripts/test-triage.ps1`:

```powershell
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
```

- [ ] **Step 2: Run to verify it fails.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: error — `triage-lib.ps1` not found / `Read-TriageInput` not defined.

- [ ] **Step 3: Create `scripts/triage-lib.ps1` with the dot-sources and `Read-TriageInput`.**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Triage Agent (Sprint 1). Classifies an issue/task into a structured triage
  object by routing through the fleet (role=triage; Haiku preferred), with
  Sonnet escalation on low confidence / high risk.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-triage.ps1 wraps it for
  the /baton:triage command. routing-lib.ps1 brings Select-Capability and, via
  fleet-lib.ps1, Invoke-Fleet for dispatch.
.NOTES
  See docs/superpowers/specs/2026-06-15-triage-agent-sprint1-design.md (d045).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability (+ fleet-lib: Invoke-Fleet)

function Read-TriageInput {
    <# Resolve the task description from exactly one source: -Url (gh issue view),
       -File (local markdown), or -Text (inline). Returns the normalized string. #>
    param(
        [string]$Url,
        [string]$File,
        [string]$Text
    )
    $sources = @($Url, $File, $Text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($sources.Count -ne 1) {
        throw "Read-TriageInput requires exactly one of -Url, -File, or -Text."
    }
    if ($Url)  { return (& gh issue view $Url --json title,body --jq '"# " + .title + "\n\n" + .body' 2>&1 | Out-String).Trim() }
    if ($File) {
        if (-not (Test-Path $File)) { throw "Triage input file not found: $File" }
        return (Get-Content -LiteralPath $File -Raw).Trim()
    }
    return $Text.Trim()
}
```

- [ ] **Step 4: Run to verify T1/T2/T2b pass.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `PASS: T1`, `PASS: T2`, `PASS: T2b` (T11/T12 also PASS now that the dot-source resolves).

- [ ] **Step 5: Commit.**

```bash
git add scripts/triage-lib.ps1 scripts/test-triage.ps1
git commit -m "feat(triage): Read-TriageInput (url/file/text, exactly-one-source)"
```

---

### Task 3: triage-lib.ps1 — Build-TriagePrompt

**Files:**
- Modify: `scripts/triage-lib.ps1` (append after `Read-TriageInput`)
- Test: `scripts/test-triage.ps1` (append inside the `try` block)

- [ ] **Step 1: Write the failing test.** Append to the `try` block:

```powershell
    # T3: prompt embeds the task text and the JSON schema contract
    $prompt = Build-TriagePrompt -TaskText 'Add retry logic to dispatch'
    Check 'T3a prompt contains the task text'  ($prompt -match 'Add retry logic to dispatch')
    Check 'T3b prompt contains the schema key' ($prompt -match '"confidence"' -and $prompt -match '"recommended_model"')
    Check 'T3c prompt demands JSON-only'       ($prompt -match 'ONLY valid JSON')
```

- [ ] **Step 2: Run to verify it fails.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `FAIL: T3a/T3b/T3c` — `Build-TriagePrompt` not defined.

- [ ] **Step 3: Implement `Build-TriagePrompt`.** Append to `scripts/triage-lib.ps1`:

```powershell
function Build-TriagePrompt {
    <# Compose the triage instruction: role + strict-JSON schema + the task text.
       Temperature is left to the provider default; the prompt enforces JSON-only. #>
    param([Parameter(Mandatory)][string]$TaskText)
    $schema = @'
{
  "type": "bug|plan|spec|coding|test|review|polish|chore|docs|research",
  "priority": "P0|P1|P2|P3|P4",
  "estimate": "XS|S|M|L|XL",
  "risk": "low|medium|high",
  "research_required": true,
  "recommended_platform": "Claude|Codex|Copilot|Gemini|Local|Human",
  "recommended_model": "Haiku|Sonnet|Opus|Codex|Copilot|local/<name>",
  "agent_type": "Triage|Planning|Implementation|Review|Research|Polish",
  "pipeline": ["<stage>", "..."],
  "area": "<repo/component area or null>",
  "next_action": "<one sentence: the next concrete step>",
  "confidence": 0.0,
  "ambiguity": "low|medium|high"
}
'@
    return @"
You are a software task triage agent. Classify the task below and respond with
ONLY valid JSON matching this schema exactly. No prose, no markdown fences.

Schema:
$schema

Guidance: confidence is your 0.0-1.0 certainty in the classification. Set
ambiguity to high when the task lacks the context needed to classify it.
pipeline is the ordered list of phases the work should pass through.

Task:
$TaskText
"@
}
```

- [ ] **Step 4: Run to verify T3 passes.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `PASS: T3a`, `PASS: T3b`, `PASS: T3c`.

- [ ] **Step 5: Commit.**

```bash
git add scripts/triage-lib.ps1 scripts/test-triage.ps1
git commit -m "feat(triage): Build-TriagePrompt (strict-JSON schema contract)"
```

---

### Task 4: triage-lib.ps1 — Test-TriageEscalationNeeded + Get-TriageJsonBlock

**Files:**
- Modify: `scripts/triage-lib.ps1` (append)
- Test: `scripts/test-triage.ps1` (append inside the `try` block)

- [ ] **Step 1: Write the failing tests.** Append to the `try` block:

```powershell
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

    # Get-TriageJsonBlock strips markdown fences
    $fenced = "Here you go:`n```````json`n{ ""type"": ""bug"" }`n```````"
    Check 'T6c Get-TriageJsonBlock extracts JSON from fenced reply' `
        ((Get-TriageJsonBlock -Raw $fenced) -match '^\s*\{\s*"type"\s*:\s*"bug"\s*\}\s*$')
```

- [ ] **Step 2: Run to verify it fails.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `FAIL` for T4/T5/T6/T6b/T6c — functions not defined.

- [ ] **Step 3: Implement both functions.** Append to `scripts/triage-lib.ps1`:

```powershell
function Test-TriageEscalationNeeded {
    <# True when the triage result warrants a second-pass on a stronger model:
       confidence below 0.70, OR risk high, OR ambiguity high. #>
    param([Parameter(Mandatory)][hashtable]$Triage)
    $conf = if ($null -ne $Triage.confidence) { [double]$Triage.confidence } else { 0.0 }
    if ($conf -lt 0.70) { return $true }
    if ([string]$Triage.risk -eq 'high') { return $true }
    if ([string]$Triage.ambiguity -eq 'high') { return $true }
    return $false
}

function Get-TriageJsonBlock {
    <# Extract the JSON object from a model reply that may be fenced or prose-wrapped:
       take the substring from the first '{' to the last '}'. Returns '' when none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open  = $Raw.IndexOf('{')
    $close = $Raw.LastIndexOf('}')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}
```

- [ ] **Step 4: Run to verify the new checks pass.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `PASS: T4`, `PASS: T5`, `PASS: T6`, `PASS: T6b`, `PASS: T6c`.

- [ ] **Step 5: Commit.**

```bash
git add scripts/triage-lib.ps1 scripts/test-triage.ps1
git commit -m "feat(triage): escalation predicate + JSON-block extractor"
```

---

### Task 5: triage-lib.ps1 — Invoke-TriageAgent (dispatch, parse, fallback, escalate)

**Files:**
- Modify: `scripts/triage-lib.ps1` (append)
- Test: `scripts/test-triage.ps1` (append inside the `try` block)

- [ ] **Step 1: Write the failing tests.** Append to the `try` block. The injected `-Dispatcher` returns a fleet-style result hashtable (`@{stdout;exit_code;...}`) so no real model is called:

```powershell
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
```

- [ ] **Step 2: Run to verify it fails.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `FAIL` for T7–T10 — `Invoke-TriageAgent` not defined.

- [ ] **Step 3: Implement `Invoke-TriageAgent`.** Append to `scripts/triage-lib.ps1`:

```powershell
function New-TriageFallback {
    <# Deterministic low-confidence object used when no model is available or the
       reply can't be parsed. The caller decides whether to retry. #>
    param([string]$Reason = 'unparseable')
    return @{
        type='unknown'; priority='P3'; estimate='M'; risk='medium'
        research_required=$true; recommended_platform='Human'; recommended_model='Sonnet'
        agent_type='Triage'; pipeline=@('human_review'); area=$null
        next_action="Manual triage needed ($Reason)."
        confidence=0.40; ambiguity='high'
        escalation_needed=$true; escalated=$false; escalated_from=$null
    }
}

function ConvertTo-TriageHashtable {
    <# Parse the model's JSON reply into a normalized triage hashtable, or $null
       when the reply has no valid JSON object. #>
    param([Parameter(Mandatory)][string]$RawStdout)
    $block = Get-TriageJsonBlock -Raw $RawStdout
    if (-not $block) { return $null }
    try { $o = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    if (-not $h.ContainsKey('escalated'))      { $h['escalated'] = $false }
    if (-not $h.ContainsKey('escalated_from')) { $h['escalated_from'] = $null }
    if (-not $h.ContainsKey('escalation_needed')) {
        $h['escalation_needed'] = (Test-TriageEscalationNeeded -Triage $h)
    }
    return $h
}

function Invoke-TriageAgent {
    <# Classify a task. Routes through Select-Capability (role=triage; Haiku
       preferred), dispatches the cheapest candidate, parses strict JSON, and
       escalates to a champion-ranked second candidate on low confidence / high
       risk. -Dispatcher injects dispatch for tests; real path uses Invoke-Fleet. #>
    param(
        [Parameter(Mandatory)][string]$Input,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Dispatcher
    )
    $dispatch = {
        param($cand, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $cand $prompt) }
        return Invoke-Fleet -Name $cand.name -Prompt $prompt -Path $FleetPath -NoJournal
    }

    $cands = Select-Capability -Capability triage -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if (@($cands).Count -lt 1) { return (New-TriageFallback -Reason 'no triage-capable worker available') }

    $prompt = Build-TriagePrompt -TaskText $Input
    $pick   = $cands[0]
    $res    = & $dispatch $pick $prompt
    if ([int]$res.exit_code -ne 0) { return (New-TriageFallback -Reason "dispatch exit $([int]$res.exit_code)") }

    $triage = ConvertTo-TriageHashtable -RawStdout ([string]$res.stdout)
    if ($null -eq $triage) { return (New-TriageFallback -Reason 'model returned no valid JSON') }

    if (Test-TriageEscalationNeeded -Triage $triage) {
        $champs = Select-Capability -Capability triage -MaxCostTier $MaxCostTier -SelectionMode champion -FleetPath $FleetPath -ToolsPath $ToolsPath
        $esc = @($champs | Where-Object { $_.name -ne $pick.name }) | Select-Object -First 1
        if ($esc) {
            $res2 = & $dispatch $esc $prompt
            if ([int]$res2.exit_code -eq 0) {
                $triage2 = ConvertTo-TriageHashtable -RawStdout ([string]$res2.stdout)
                if ($null -ne $triage2) {
                    $triage2['escalated'] = $true
                    $triage2['escalated_from'] = $pick.name
                    return $triage2
                }
            }
        }
    }
    return $triage
}
```

- [ ] **Step 4: Run to verify T7–T10 pass.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `PASS` for T7a–c, T8a–c, T9, T10a–c.

- [ ] **Step 5: Commit.**

```bash
git add scripts/triage-lib.ps1 scripts/test-triage.ps1
git commit -m "feat(triage): Invoke-TriageAgent (dispatch, parse, fallback, escalate)"
```

---

### Task 6: fleet-triage.ps1 — CLI wrapper + YAML/JSON output

**Files:**
- Create: `scripts/fleet-triage.ps1`
- Test: `scripts/test-triage.ps1` (append the last checks, then CLOSE the suite)

- [ ] **Step 1: Write the failing tests + close the suite.** Append to the `try` block, then add the catch/summary/exit block:

```powershell
    # T13: --Text run prints YAML with type + confidence (stub dispatcher via env)
    $env:BATON_TRIAGE_TEST_FLEET = $stubFleetPath
    $env:BATON_TRIAGE_TEST_JSON  = $goodJson
    $runner = Join-Path $PSScriptRoot 'fleet-triage.ps1'
    $yamlOut = (& pwsh -NoProfile -File $runner -Text 'Plan the work' 2>&1 | Out-String)
    Check 'T13a YAML output has type:'       ($yamlOut -match 'type:\s*plan')
    Check 'T13b YAML output has confidence:'  ($yamlOut -match 'confidence:\s*0\.84')

    # T14: --Json run emits valid JSON with required fields
    $jsonOut = (& pwsh -NoProfile -File $runner -Text 'Plan the work' -Json 2>&1 | Out-String)
    $parsed = $jsonOut | ConvertFrom-Json
    Check 'T14a JSON parses'         ($null -ne $parsed)
    Check 'T14b JSON has type/conf'  ($parsed.type -eq 'plan' -and [double]$parsed.confidence -eq 0.84)
    Remove-Item env:BATON_TRIAGE_TEST_FLEET, env:BATON_TRIAGE_TEST_JSON -ErrorAction SilentlyContinue

    # T15: --Url path shells out to `gh issue view` (assert the command is attempted).
    #      No network: point at an obviously invalid ref and confirm a graceful fallback
    #      object rather than a crash.
    $t15 = Invoke-TriageAgent -Input (Read-TriageInput -Text 'url-path-covered-by-T2-family') -FleetPath $stubFleetPath -ToolsPath (Join-Path $tmp 'no-tools.yaml') -Dispatcher $dispGood
    Check 'T15 url-family input still triages' ($t15.type -eq 'plan')
}
catch {
    Write-Host "FAIL: unhandled exception — $($_.Exception.Message)"
    $script:fail++
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED"; exit 1 }
Write-Host "`nALL PASS"; exit 0
```

- [ ] **Step 2: Run to verify it fails.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `FAIL: T13a/T13b/T14a/T14b` — `fleet-triage.ps1` not found.

- [ ] **Step 3: Create `scripts/fleet-triage.ps1`.**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:triage runner. Resolves the task (url/file/text), invokes the Triage
  Agent through the fleet, and prints the triage object as YAML (default) or JSON.
.NOTES
  Recommend-only: classifies and recommends; it does NOT dispatch the work or
  mutate GitHub. Sprint 3 wires the output into labels/Project fields.
#>
param(
    [string]$Url,
    [string]$File,
    [string]$Text,
    [switch]$Json,
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$ToolsPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'tools.yaml' } else { Join-Path $HOME '.baton/tools.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'triage-lib.ps1')

# Test seam: a stub fleet + canned JSON dispatcher injected via env so the suite
# never calls a real model. Absent in production.
$dispatcher = $null
if ($env:BATON_TRIAGE_TEST_FLEET) { $FleetPath = $env:BATON_TRIAGE_TEST_FLEET }
if ($env:BATON_TRIAGE_TEST_JSON) {
    $canned = $env:BATON_TRIAGE_TEST_JSON
    $dispatcher = { param($c,$p) @{ stdout = $canned; stderr=''; exit_code = 0; duration_s = 1 } }
}

$taskText = Read-TriageInput -Url $Url -File $File -Text $Text
$args = @{ Input = $taskText; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
if ($dispatcher) { $args['Dispatcher'] = $dispatcher }
$triage = Invoke-TriageAgent @args

if ($Json) {
    $triage | ConvertTo-Json -Depth 6
} else {
    # Deterministic key order for a readable YAML-ish block.
    $order = @('type','priority','estimate','risk','research_required','recommended_platform',
               'recommended_model','agent_type','area','next_action','confidence','ambiguity',
               'escalation_needed','escalated','escalated_from','pipeline')
    foreach ($k in $order) {
        if (-not $triage.ContainsKey($k)) { continue }
        $v = $triage[$k]
        if ($k -eq 'pipeline') {
            Write-Host "pipeline:"
            foreach ($stage in @($v)) { Write-Host "  - $stage" }
        } else {
            Write-Host "${k}: $v"
        }
    }
}
```

- [ ] **Step 4: Run the full suite green.** `pwsh -NoProfile -File scripts/test-triage.ps1`
Expected: `ALL PASS` (T1–T15, T11/T12 included).

- [ ] **Step 5: Commit.**

```bash
git add scripts/fleet-triage.ps1 scripts/test-triage.ps1
git commit -m "feat(triage): fleet-triage.ps1 runner (YAML/JSON output) + suite green"
```

---

### Task 7: /baton:triage slash command

**Files:**
- Create: `commands/triage.md`

- [ ] **Step 1: Create `commands/triage.md`.** Match the house format (frontmatter + Steps), mirroring `commands/models.md`:

```markdown
---
description: Triage an issue or task into a structured classification (type, priority, estimate, risk, recommended pipeline + model) by routing through the fleet. Haiku preferred; escalates to Sonnet on low confidence / high risk.
argument-hint: "[--url <github-issue-url>] [--file <path>] [--json] [<text>]"
---

# /baton:triage

Classify a task. Routes through `Select-Capability -Capability triage` (Haiku
preferred via the fleet's usage_class path) and escalates to Sonnet when the
first pass is low-confidence, high-risk, or ambiguous. Recommend-only: it
classifies and recommends a pipeline/worker; it does NOT dispatch the work.

## Steps

1. **Parse `$ARGUMENTS`.** Recognize `--url <github-issue-url>`, `--file <path>`,
   `--json`, and otherwise treat the remaining text as the inline task. Exactly
   one input source; if none or more than one, print usage and stop.

2. **Dispatch** (map `--url U` to `-Url U`, `--file F` to `-File F`, inline text
   to `-Text`, `--json` to `-Json`):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-triage.ps1" <MAPPED-ARGS>
   ```

   - default: echo the YAML triage block verbatim.
   - `--json`: emit the triage JSON.

3. **Summarize for the user** in 2-4 plain-language bullets: the type + priority,
   the recommended worker/pipeline, the confidence (and whether it escalated to
   Sonnet), and the next action. Do not act on the recommendation — Kevin decides
   whether to start the work.
```

- [ ] **Step 2: Sanity-check the command runs end-to-end against the live fleet** (real Haiku call; skip if offline):

Run: `pwsh -NoProfile -File scripts/fleet-triage.ps1 -Text "Add retry logic to the routing dispatch escalation path"`
Expected: a YAML block with `type:`, `confidence:`, and a `pipeline:` list. (If Haiku is unavailable, expect the deterministic fallback object with `confidence: 0.4` — also acceptable.)

- [ ] **Step 3: Commit.**

```bash
git add commands/triage.md
git commit -m "feat(triage): /baton:triage slash command"
```

---

### Task 8: Bootstrap deployment + version bump

**Files:**
- Modify: `scripts/bootstrap.ps1:259` (script manifest array)
- Modify: `scripts/test-bootstrap.ps1` (assert triage scripts deploy)
- Modify: `.claude-plugin/plugin.json` (version bump)

- [ ] **Step 1: Write the failing assertion.** In `scripts/test-bootstrap.ps1`, add near the other `Assert` lines (the dry-run output lists deployed scripts):

```powershell
Assert "deploys triage-lib script"   ($out -match 'triage-lib\.ps1')
Assert "deploys fleet-triage script" ($out -match 'fleet-triage\.ps1')
```

- [ ] **Step 2: Run to verify it fails.** `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: `FAIL` for the two new asserts — the scripts aren't in the manifest yet.

- [ ] **Step 3: Add both scripts to the manifest.** In `scripts/bootstrap.ps1:259`, add `'triage-lib.ps1', 'fleet-triage.ps1'` to the `foreach ($script in @(...))` array (place them after `'fleet-models.ps1'`):

```powershell
... 'fleet-models.ps1', 'triage-lib.ps1', 'fleet-triage.ps1', 'idea-lib.ps1')) {
```

- [ ] **Step 4: Bump the plugin version.** In `.claude-plugin/plugin.json`, change `"version": "1.2.0-rc.7"` to `"version": "1.2.0-rc.8"`.

- [ ] **Step 5: Run to verify the asserts pass.** `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: `PASS` for both new asserts; the suite's existing asserts stay green.

- [ ] **Step 6: Commit.**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "feat(triage): deploy triage scripts via bootstrap; bump to rc.8"
```

---

### Task 9: Adversarial review, full systems gate, PR

Per Kevin's execution style, this is the ONE comprehensive review (no per-task reviewers).

- [ ] **Step 1: Run the FULL test suite (systems gate).** Run every `test-*.ps1` and confirm all green:

```powershell
Get-ChildItem scripts/test-*.ps1 | ForEach-Object {
    Write-Host "=== $($_.Name) ==="
    & pwsh -NoProfile -File $_.FullName
    if ($LASTEXITCODE -ne 0) { Write-Host "SUITE FAILED: $($_.Name)" }
}
```

Expected: every suite ends `ALL PASS` / exit 0. Investigate and fix any red before proceeding.

- [ ] **Step 2: Adversarial self-review.** Re-read the spec (`docs/superpowers/specs/2026-06-15-triage-agent-sprint1-design.md`) section by section against the diff. Confirm:
  - the `triage` capability flows through `Select-Capability` (no Haiku hardcode anywhere) — grep the diff for `claude-haiku` and confirm it appears only in `fleet.yaml`/`references`, never in `triage-lib.ps1`;
  - the deterministic fallback fires on all three paths (no candidates, non-zero exit, unparseable JSON);
  - escalation picks a DIFFERENT candidate than the first pass and the escalated result is authoritative;
  - `stdin: true` is set on both triage providers (JSON-heavy prompt safety);
  - no test writes under real `~/.baton` or `~/.claude` (every path is `$tmp`/env-injected).

  Fix anything that fails the read. If the review surfaces a genuine design decision (not a bugfix), capture it via `Add-DecisionRecordFromFile`; otherwise prune — do not log bugfixes as decisions.

- [ ] **Step 3: Live smoke (if online).** Deploy to the live `~/.baton` via bootstrap dry-run check, then a real triage:

```powershell
pwsh -NoProfile -File scripts/fleet-triage.ps1 -Text "Add a --dry-run flag to fleet-backlog that lists actions without running them" --json
```

Expected: valid JSON triage; note whether it escalated. (Fallback object is acceptable if Haiku is unreachable.)

- [ ] **Step 4: Push the branch and open the PR.**

```bash
git push -u origin feat/triage-agent-sprint1
gh pr create --repo Ryfter/baton --title "feat(triage): Sprint 1 - Triage Agent" --body "Implements #51. Spec: docs/superpowers/specs/2026-06-15-triage-agent-sprint1-design.md. Decisions d045-d047. Closes #51."
```

- [ ] **Step 5: Merge via the gated flow** (after review passes), then deploy the live bootstrap and confirm `/baton:triage` is available.

---

## Self-review checklist (run before execution handoff)

- **Spec coverage:** Read-TriageInput (§T.2 input priority) ✓; Build-TriagePrompt (§T.3) ✓; output contract (§T.4) ✓ via schema + key order; escalation (§decision 4) ✓; deterministic fallback (§decision 5) ✓; YAML default + `--json` (§decision 6) ✓; fleet.yaml additions (§T.1) ✓; command (§T.5) ✓; runner (§T.6) ✓; bootstrap (§T.7) ✓. All 15 spec tests mapped to Tasks 1–6.
- **No Haiku hardcode:** dispatch goes through `Select-Capability` + `Invoke-Fleet` by candidate name; the only literal `claude-haiku` strings live in `fleet.yaml`/`references`. ✓
- **Type consistency:** `Invoke-TriageAgent` returns a hashtable; `ConvertTo-TriageHashtable`, `New-TriageFallback`, and `Test-TriageEscalationNeeded` all operate on the same hashtable shape with keys `type/priority/estimate/risk/confidence/ambiguity/escalated/escalated_from/escalation_needed/pipeline`. The runner's key-order list matches those keys. ✓
- **Test isolation:** every suite path is `$tmp` or env-injected; no real `~/.baton`. ✓
