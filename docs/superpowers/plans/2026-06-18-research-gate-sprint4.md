# Research Gate (Sprint 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/baton:research-gate` — a build/adopt/adapt/inconclusive verdict gate that grounds a cheap governed-fleet model in real evidence (local tool registry + prior research ensemble + KB + optional live search) before non-trivial work.

**Architecture:** A pure layer (parse/format/assemble, no network or model) plus a seamed dispatch layer with two injectable scriptblocks — `-Searcher` (evidence) and `-Dispatcher` (model). The CLI resolves input + the active job's research phase and writes the verdict memo. Mirrors the Triage Agent (`triage-lib.ps1` + `fleet-triage.ps1`) and Projects Sync structure.

**Tech Stack:** PowerShell 7 (pwsh). Hand-rolled `Check($n,$c)` test harness. `Select-Capability` (routing-lib) for governed routing; `Invoke-Fleet` (fleet-lib) for real dispatch; `Read-Tools` (routing-lib) for the registry; `Invoke-KbSearch` (kb-lib) for KB hits; `Read-CurrentJob`/`Read-Manifest` (job-lib) for job context.

## Global Constraints

- **Box-private:** worker rosters/endpoints/budgets live only in the live `~/.baton/fleet.yaml`; the committed seed `references/fleet.yaml` carries only placeholders and capability tags. Never write real inventory into the repo.
- **965-byte shell limit:** every shell command argument stays under 965 bytes; use files for anything large.
- **Tests never touch reality:** no network, no real model, no real job dir. Both seams (`-Searcher`, `-Dispatcher`) stubbed; job dirs are temp dirs; KB guarded so a missing python/kb is a silent no-op.
- **Array-return idiom (hard-won lesson):** the unary comma `,([type[]]$x)` protects a single-element array return **only at direct-assignment call sites** (`$v = Func`). At sites where the value flows into an `@()` wrapper or a hashtable member, the comma *nests* the array — drop it there, keep the `[string[]]` cast. `Get-ToolsRegistrySummary` returns to direct assignment → keep the comma.
- **Recommend-only:** the gate emits a verdict; it never dispatches the work or blocks. `inconclusive` is the honest fallback.
- **PowerShell automatic variables:** never name a parameter `$Input` or `$Event`; read bound values via `$PSBoundParameters` if a clash is unavoidable.
- **Plugin version:** bump `.claude-plugin/plugin.json` `1.2.0-rc.10` → `1.2.0-rc.11`.

---

### Task 1: Pure verdict parsing, escalation, fallback

Creates the library file and the JSON→verdict core.

**Files:**
- Create: `scripts/research-gate-lib.ps1`
- Create: `scripts/test-research-gate.ps1`

**Interfaces:**
- Produces:
  - `Get-GateJsonBlock -Raw <string>` → `string` (first `{` to last `}`, or `''`)
  - `ConvertTo-GateHashtable -RawStdout <string>` → `hashtable` or `$null`. Normalizes `options` to an array; injects defaults `escalated=$false`, `escalated_from=$null`, and `escalation_needed` (computed if absent).
  - `Test-GateEscalationNeeded -Verdict <hashtable>` → `bool` (`confidence < 0.70` OR `risk_if_wrong='high'` OR `recommendation='inconclusive'`)
  - `New-GateFallback [-Reason <string>]` → `hashtable` (`recommendation='inconclusive'`, `options=@()`, `confidence=0.30`, `risk_if_wrong='medium'`, escalation flags set)

- [ ] **Step 1: Write the failing test scaffold**

Create `scripts/test-research-gate.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/research-gate-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: pure parse / escalation / fallback ----
    $adoptJson = '{"recommendation":"adopt","options":[{"name":"markitdown","kind":"library","fit":"strong","note":"doc->md"}],"rationale":"exists","next_action":"spike","confidence":0.82,"risk_if_wrong":"low"}'
    Check 'T1 json block extracted from prose' ((Get-GateJsonBlock -Raw ("noise " + $adoptJson + " tail")) -eq $adoptJson)
    Check 'T2 no json -> empty' ((Get-GateJsonBlock -Raw 'no braces here') -eq '')

    $v = ConvertTo-GateHashtable -RawStdout ('```json' + "`n" + $adoptJson + "`n" + '```')
    Check 'T3 fenced json parses recommendation' ($v.recommendation -eq 'adopt')
    Check 'T4 options normalized to array' (@($v.options).Count -eq 1)
    Check 'T5 escalation defaults injected' (($v.escalated -eq $false) -and ($v.ContainsKey('escalation_needed')))
    Check 'T6 garbage -> null' ($null -eq (ConvertTo-GateHashtable -RawStdout 'not json'))

    Check 'T7 low confidence escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.5; risk_if_wrong='low'; recommendation='adopt' })
    Check 'T8 high risk escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.9; risk_if_wrong='high'; recommendation='adopt' })
    Check 'T9 inconclusive escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.9; risk_if_wrong='low'; recommendation='inconclusive' })
    Check 'T10 confident low-risk adopt does not escalate' (-not (Test-GateEscalationNeeded -Verdict @{ confidence=0.85; risk_if_wrong='low'; recommendation='adopt' }))

    $fb = New-GateFallback -Reason 'no worker'
    Check 'T11 fallback is inconclusive' ($fb.recommendation -eq 'inconclusive')
    Check 'T12 fallback has no options' (@($fb.options).Count -eq 0)
    Check 'T13 fallback flagged for escalation' ($fb.escalation_needed -eq $true)
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: FAIL — `research-gate-lib.ps1` does not exist / functions undefined.

- [ ] **Step 3: Create the library with the pure core**

Create `scripts/research-gate-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Research Gate (Sprint 4). Emits a build/adopt/adapt/inconclusive verdict for a
  task by grounding a cheap governed-fleet model in real evidence (local tool
  registry + prior research ensemble + KB + optional live search).
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-research-gate.ps1 wraps it
  for /baton:research-gate. routing-lib brings Select-Capability + Read-Tools and,
  via fleet-lib, Invoke-Fleet. Recommend-only — never blocks, never dispatches work.
.NOTES
  See docs/superpowers/specs/2026-06-18-research-gate-sprint4-design.md (d-rg-1..6).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability, Read-Tools (+ fleet-lib: Invoke-Fleet)

function Get-GateJsonBlock {
    <# Extract the JSON object from a reply that may be fenced or prose-wrapped:
       first '{' to last '}'. Returns '' when none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open  = $Raw.IndexOf('{')
    $close = $Raw.LastIndexOf('}')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function New-GateFallback {
    <# Deterministic inconclusive verdict when no model is available or the reply
       can't be parsed. The caller decides whether to retry / go deep. #>
    param([string]$Reason = 'unparseable')
    return @{
        recommendation='inconclusive'; options=@()
        rationale="Automated research gate could not produce a verdict ($Reason)."
        next_action='Run with --deep, or research manually before deciding build/adopt/adapt.'
        confidence=0.30; risk_if_wrong='medium'
        escalation_needed=$true; escalated=$false; escalated_from=$null
    }
}

function Test-GateEscalationNeeded {
    <# True when the verdict warrants a second pass on a stronger model:
       confidence below 0.70, OR risk_if_wrong high, OR recommendation inconclusive. #>
    param([Parameter(Mandatory)][hashtable]$Verdict)
    $conf = if ($null -ne $Verdict.confidence) { [double]$Verdict.confidence } else { 0.0 }
    if ($conf -lt 0.70) { return $true }
    if ([string]$Verdict.risk_if_wrong -eq 'high') { return $true }
    if ([string]$Verdict.recommendation -eq 'inconclusive') { return $true }
    return $false
}

function ConvertTo-GateHashtable {
    <# Parse the model's JSON reply into a normalized verdict hashtable, or $null
       when the reply has no valid JSON object. #>
    param([Parameter(Mandatory)][string]$RawStdout)
    $block = Get-GateJsonBlock -Raw $RawStdout
    if (-not $block) { return $null }
    try { $o = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    if ($null -eq $h['options']) { $h['options'] = @() } else { $h['options'] = @($h['options']) }
    if (-not $h.ContainsKey('escalated'))      { $h['escalated'] = $false }
    if (-not $h.ContainsKey('escalated_from')) { $h['escalated_from'] = $null }
    if (-not $h.ContainsKey('escalation_needed')) {
        $h['escalation_needed'] = (Test-GateEscalationNeeded -Verdict $h)
    }
    return $h
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: PASS — `ALL CHECKS PASS` (13 checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/research-gate-lib.ps1 scripts/test-research-gate.ps1
git commit -m "feat(research-gate): pure verdict parse/escalation/fallback (T1-T13)"
```

---

### Task 2: Pure evidence assembly, prompt, memo

**Files:**
- Modify: `scripts/research-gate-lib.ps1` (append)
- Modify: `scripts/test-research-gate.ps1` (append before the `finally`)

**Interfaces:**
- Consumes: `Read-Tools` (routing-lib, already dot-sourced).
- Produces:
  - `Get-ToolsRegistrySummary [-Path <string>]` → `string[]` of `"<name> — <capability> (<cost_tier>)"` for enabled tools (direct-assignment return → keep the unary comma)
  - `Get-EnsembleSynthesis [-JobDir <string>]` → `string` (newest `phases/research/ensemble-*/synthesis.md` text, or `''`)
  - `Build-GatePrompt -TaskText <string> [-RegistryLines <string[]>] [-EnsembleText <string>] [-KbHits <array>] [-SearchEvidence <array>]` → `string`
  - `Format-GateMemo -Verdict <hashtable>` → `string` (markdown memo)

- [ ] **Step 1: Write the failing tests** (append before `finally` in `test-research-gate.ps1`)

```powershell
    # ---- Task 2: evidence / prompt / memo (pure) ----
    $toolsYaml = @"
tools:
  - name: docling
    enabled: true
    cost_tier: local
    capability: pdf-extract
  - name: disabled-tool
    enabled: false
    cost_tier: local
    capability: ocr
"@
    $tmpTools = Join-Path $tmpDir 'tools.yaml'
    Set-Content -Path $tmpTools -Value $toolsYaml -Encoding utf8NoBOM
    $reg = Get-ToolsRegistrySummary -Path $tmpTools
    Check 'T14 registry lists enabled tool' ($reg -contains 'docling — pdf-extract (local)')
    Check 'T15 registry omits disabled tool' (-not (@($reg) | Where-Object { $_ -like 'disabled-tool*' }))

    $jobDir = Join-Path $tmpDir 'job1'
    $ensDir = Join-Path $jobDir 'phases/research/ensemble-2026-06-18T10-00-00'
    New-Item -ItemType Directory -Force -Path $ensDir | Out-Null
    Set-Content -Path (Join-Path $ensDir 'synthesis.md') -Value 'PRIOR FINDINGS HERE' -Encoding utf8NoBOM
    Check 'T16 ensemble synthesis found' ((Get-EnsembleSynthesis -JobDir $jobDir) -match 'PRIOR FINDINGS')
    Check 'T17 no job dir -> empty synthesis' ((Get-EnsembleSynthesis -JobDir (Join-Path $tmpDir 'nojob')) -eq '')

    $prompt = Build-GatePrompt -TaskText 'convert pdfs to markdown' -RegistryLines $reg -EnsembleText 'PRIOR FINDINGS' -KbHits @() -SearchEvidence @()
    Check 'T18 prompt includes task' ($prompt -match 'convert pdfs to markdown')
    Check 'T19 prompt includes registry evidence' ($prompt -match 'docling')
    Check 'T20 prompt includes verdict schema' ($prompt -match 'build\|adopt\|adapt\|inconclusive')

    $memo = Format-GateMemo -Verdict @{ recommendation='adopt'; confidence=0.8; risk_if_wrong='low'
        options=@([pscustomobject]@{ name='markitdown'; kind='library'; fit='strong'; note='doc->md' })
        rationale='exists already'; next_action='spike it'; escalated=$false }
    Check 'T21 memo shows recommendation' ($memo -match 'ADOPT')
    Check 'T22 memo lists option' ($memo -match 'markitdown')
    Check 'T23 memo shows next action' ($memo -match 'spike it')
```

- [ ] **Step 2: Run to verify new tests fail**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: FAIL — `Get-ToolsRegistrySummary` etc. undefined (T14+).

- [ ] **Step 3: Append the implementations** to `scripts/research-gate-lib.ps1`

```powershell
function Get-ToolsRegistrySummary {
    <# Compact "name — capability (cost_tier)" lines for enabled tools — the local
       'do we already have it wired?' grounding. Returns string[]; '' inputs -> @(). #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return ,([string[]]@()) }
    $lines = foreach ($t in (Read-Tools -Path $Path)) {
        if ($t.enabled -ne $true) { continue }
        "$($t.name) — $($t.capability) ($($t.cost_tier))"
    }
    return ,([string[]]$lines)
}

function Get-EnsembleSynthesis {
    <# Newest phases/research/ensemble-*/synthesis.md under a job dir, or '' when
       there is no job / no prior ensemble. Reads files only — no network. #>
    param([string]$JobDir)
    if (-not $JobDir -or -not (Test-Path $JobDir)) { return '' }
    $researchDir = Join-Path $JobDir 'phases/research'
    if (-not (Test-Path $researchDir)) { return '' }
    $hit = Get-ChildItem -Path $researchDir -Recurse -Filter 'synthesis.md' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $hit) { return '' }
    return (Get-Content -LiteralPath $hit.FullName -Raw).Trim()
}

function Build-GatePrompt {
    <# Compose the gate instruction: role + strict-JSON verdict schema + an evidence
       block (local registry, prior ensemble, KB, live search) + the task text. #>
    param(
        [Parameter(Mandatory)][string]$TaskText,
        [string[]]$RegistryLines = @(),
        [string]$EnsembleText = '',
        [array]$KbHits = @(),
        [array]$SearchEvidence = @()
    )
    $schema = @'
{
  "recommendation": "build|adopt|adapt|inconclusive",
  "options": [
    { "name": "<tool/lib/service/internal>", "kind": "library|tool|service|internal",
      "fit": "strong|partial|weak", "note": "<one line: what it is + why it fits or not>" }
  ],
  "rationale": "<why this recommendation>",
  "next_action": "<one concrete next step>",
  "confidence": 0.0,
  "risk_if_wrong": "low|medium|high"
}
'@
    $evidence = "## Evidence`n"
    if ($RegistryLines.Count) { $evidence += "`nTools already wired locally:`n" + (($RegistryLines | ForEach-Object { "- $_" }) -join "`n") + "`n" }
    else { $evidence += "`nTools already wired locally: (none)`n" }
    if ($EnsembleText)  { $evidence += "`nPrior research ensemble synthesis:`n$EnsembleText`n" }
    if ($KbHits.Count)  { $evidence += "`nRelevant prior knowledge (KB):`n" + (($KbHits | ForEach-Object { "- $($_.source): $((""$($_.text)"" -replace '\s+',' ').Trim())" }) -join "`n") + "`n" }
    if ($SearchEvidence.Count) { $evidence += "`nLive web/registry search results:`n" + (($SearchEvidence | ForEach-Object { "- $($_.title) ($($_.url)): $($_.snippet)" }) -join "`n") + "`n" }

    return @"
You are a software research gate. Decide whether the task below should be built
from scratch, or whether something already exists to adopt or adapt. Use the
Evidence. Respond with ONLY valid JSON matching this schema exactly — no prose,
no markdown fences.

Schema:
$schema

Guidance: prefer adopt/adapt when a strong/partial-fit option exists; recommend
build only when nothing fits; recommend inconclusive when the evidence is too thin
to decide. confidence is your 0.0-1.0 certainty. List concrete options with honest
fit ratings.

$evidence

## Task
$TaskText
"@
}

function Format-GateMemo {
    <# Human-readable markdown memo from a verdict hashtable. #>
    param([Parameter(Mandatory)][hashtable]$Verdict)
    $rec  = ([string]$Verdict.recommendation).ToUpperInvariant()
    $conf = if ($null -ne $Verdict.confidence) { '{0:0.00}' -f [double]$Verdict.confidence } else { 'n/a' }
    $risk = [string]$Verdict.risk_if_wrong
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("RESEARCH GATE — recommendation: $rec  (confidence $conf, risk-if-wrong $risk)")
    if ($Verdict.escalated -eq $true) { [void]$sb.AppendLine("(escalated from $($Verdict.escalated_from))") }
    [void]$sb.AppendLine("Options:")
    foreach ($o in @($Verdict.options)) {
        [void]$sb.AppendLine("  • $($o.name) ($($o.kind), $($o.fit)) — $($o.note)")
    }
    [void]$sb.AppendLine("Rationale: $($Verdict.rationale)")
    [void]$sb.AppendLine("Next action: $($Verdict.next_action)")
    return $sb.ToString().TrimEnd()
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: PASS — 23 checks.

- [ ] **Step 5: Commit**

```bash
git add scripts/research-gate-lib.ps1 scripts/test-research-gate.ps1
git commit -m "feat(research-gate): evidence/prompt/memo pure layer (T14-T23)"
```

---

### Task 3: Seamed evidence search (`Invoke-EvidenceSearch`)

**Files:**
- Modify: `scripts/research-gate-lib.ps1` (append)
- Modify: `scripts/test-research-gate.ps1` (append)

**Interfaces:**
- Produces:
  - `Invoke-EvidenceSearch -Query <string> [-Searcher <scriptblock>] [-Deep]` → normalized `array` of `@{ source; title; snippet; url }`. Offline (no `-Deep`) makes **zero** searcher calls and returns `@()`. A searcher that throws degrades to `@()` (never throws).

- [ ] **Step 1: Write the failing tests** (append before `finally`)

```powershell
    # ---- Task 3: seamed evidence search ----
    $script:searchCalls = 0
    $stubSearcher = { param($q) $script:searchCalls++; @(
        [pscustomobject]@{ source='web'; title='markitdown'; snippet='doc to md'; url='https://x/md' }) }
    Check 'T24 offline makes zero searcher calls' (
        ((Invoke-EvidenceSearch -Query 'q' -Searcher $stubSearcher).Count -eq 0) -and ($script:searchCalls -eq 0))
    $ev = Invoke-EvidenceSearch -Query 'q' -Searcher $stubSearcher -Deep
    Check 'T25 deep gathers normalized evidence' ((@($ev).Count -eq 1) -and ($ev[0].title -eq 'markitdown') -and ($script:searchCalls -eq 1))
    $throwSearcher = { param($q) throw 'network down' }
    Check 'T26 searcher throw degrades to empty (no throw)' ((Invoke-EvidenceSearch -Query 'q' -Searcher $throwSearcher -Deep).Count -eq 0)
```

- [ ] **Step 2: Run to verify fail**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: FAIL — `Invoke-EvidenceSearch` undefined (T24+).

- [ ] **Step 3: Append the implementation**

```powershell
function Invoke-EvidenceSearch {
    <# Gather external evidence via the -Searcher seam (default: real web +
       package-registry search). Only runs under -Deep; offline returns @() with
       ZERO searcher calls. Normalizes each result to @{source;title;snippet;url}.
       A searcher error degrades to @() — never throws (graceful degradation). #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [scriptblock]$Searcher = { param($q) Invoke-RealEvidenceSearch -Query $q },
        [switch]$Deep
    )
    if (-not $Deep) { return ,(@()) }
    try {
        $raw = & $Searcher $Query
    } catch {
        Write-Debug "Invoke-EvidenceSearch: $($_.Exception.Message)"
        return ,(@())
    }
    $norm = foreach ($r in @($raw)) {
        [pscustomobject]@{
            source  = [string]$r.source
            title   = [string]$r.title
            snippet = [string]$r.snippet
            url     = [string]$r.url
        }
    }
    return ,(@($norm))
}

function Invoke-RealEvidenceSearch {
    <# Default searcher: a single web/registry search round. Best-effort and
       box-private — returns @() if no search tool is wired. Replace/extend per box.
       Kept tiny on purpose: -Deep surfaces candidates; it does NOT verify existence. #>
    param([Parameter(Mandatory)][string]$Query)
    # No hard dependency on a specific search tool in the seed. A box wires its own
    # (e.g. a firecrawl/WebSearch shim) by overriding the -Searcher seam from the CLI.
    return @()
}
```

> Note on the array idiom: `Invoke-EvidenceSearch` returns to direct assignment in
> the tests and in `Invoke-ResearchGate`, so the unary comma `,(@(...))` protects the
> single/empty array shape. Keep it.

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: PASS — 26 checks.

- [ ] **Step 5: Commit**

```bash
git add scripts/research-gate-lib.ps1 scripts/test-research-gate.ps1
git commit -m "feat(research-gate): seamed evidence search, deep-gated, graceful (T24-T26)"
```

---

### Task 4: Seamed orchestration (`Invoke-ResearchGate`)

**Files:**
- Modify: `scripts/research-gate-lib.ps1` (append)
- Modify: `scripts/test-research-gate.ps1` (append)

**Interfaces:**
- Consumes: `Select-Capability` (economy + champion), `Invoke-Fleet` (real dispatch), `Invoke-KbSearch` (guarded), all pure functions above, `Invoke-EvidenceSearch`.
- Produces:
  - `Invoke-ResearchGate -Task <string> [-MaxCostTier local|free|paid='paid'] [-JobDir <string>] [-Deep] [-NoKb] [-FleetPath <string>] [-ToolsPath <string>] [-Searcher <scriptblock>] [-Dispatcher <scriptblock>]` → verdict `hashtable`. Routes synthesis through `Select-Capability -Capability research` (cheap floor), escalates to a champion-ranked second candidate on `Test-GateEscalationNeeded`. `-Dispatcher` injects dispatch for tests; real path uses `Invoke-Fleet`. `-NoKb` skips the KB call (tests set it so no python is spawned).

- [ ] **Step 1: Write the failing tests** (append before `finally`)

```powershell
    # ---- Task 4: orchestration (stubbed dispatcher + searcher) ----
    $fleetYaml = @"
providers:
  - name: rg-haiku
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [research]
    command_template: 'echo'
  - name: rg-sonnet
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [research]
    command_template: 'echo'
"@
    $tmpFleet = Join-Path $tmpDir 'fleet.yaml'
    Set-Content -Path $tmpFleet -Value $fleetYaml -Encoding utf8NoBOM

    $adoptReply = '{"recommendation":"adopt","options":[{"name":"markitdown","kind":"library","fit":"strong","note":"x"}],"rationale":"r","next_action":"n","confidence":0.85,"risk_if_wrong":"low"}'
    $okDisp = { param($c,$p) @{ stdout=$adoptReply; stderr=''; exit_code=0; duration_s=1 } }
    $rg = Invoke-ResearchGate -Task 'convert pdfs' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $okDisp
    Check 'T27 adopt verdict returned' ($rg.recommendation -eq 'adopt')
    Check 'T28 not escalated when confident' (-not ($rg.escalated -eq $true))

    $lowReply  = '{"recommendation":"adopt","options":[],"rationale":"r","next_action":"n","confidence":0.5,"risk_if_wrong":"low"}'
    $highReply = '{"recommendation":"adopt","options":[{"name":"pandoc","kind":"tool","fit":"strong","note":"y"}],"rationale":"r2","next_action":"n2","confidence":0.9,"risk_if_wrong":"low"}'
    $script:dispN = 0
    $escDisp = { param($c,$p) $script:dispN++; if ($script:dispN -eq 1) { @{ stdout=$lowReply; exit_code=0 } } else { @{ stdout=$highReply; exit_code=0 } } }
    $rg2 = Invoke-ResearchGate -Task 't' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $escDisp
    Check 'T29 low confidence triggers escalation' (($rg2.escalated -eq $true) -and ($rg2.confidence -eq 0.9))
    Check 'T30 escalated_from records first pick' ($null -ne $rg2.escalated_from)

    $failDisp = { param($c,$p) @{ stdout=''; stderr='boom'; exit_code=1 } }
    $rg3 = Invoke-ResearchGate -Task 't' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $failDisp
    Check 'T31 dispatch failure -> fallback inconclusive' ($rg3.recommendation -eq 'inconclusive')

    $emptyFleet = Join-Path $tmpDir 'empty-fleet.yaml'
    Set-Content -Path $emptyFleet -Value "providers: []" -Encoding utf8NoBOM
    $rg4 = Invoke-ResearchGate -Task 't' -FleetPath $emptyFleet -ToolsPath $tmpTools -NoKb -Dispatcher $okDisp
    Check 'T32 no worker -> fallback inconclusive' ($rg4.recommendation -eq 'inconclusive')

    $script:deepCalls = 0
    $deepSearcher = { param($q) $script:deepCalls++; @() }
    [void](Invoke-ResearchGate -Task 't' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $okDisp -Searcher $deepSearcher)
    Check 'T33 offline run makes zero searcher calls' ($script:deepCalls -eq 0)
    [void](Invoke-ResearchGate -Task 't' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $okDisp -Searcher $deepSearcher -Deep)
    Check 'T34 deep run invokes searcher' ($script:deepCalls -eq 1)
```

- [ ] **Step 2: Run to verify fail**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: FAIL — `Invoke-ResearchGate` undefined (T27+).

- [ ] **Step 3: Append the implementation**

```powershell
function Invoke-ResearchGate {
    <# Produce a build/adopt/adapt/inconclusive verdict for a task. Assembles
       evidence (local registry + prior ensemble + KB + optional live search),
       routes synthesis through Select-Capability (role=research; cheap floor,
       governed: route-around-exhausted + budget filter), dispatches the cheapest
       candidate, parses strict JSON, and escalates to a champion-ranked second
       candidate on low confidence / high risk / inconclusive. -Dispatcher and
       -Searcher inject for tests; real path uses Invoke-Fleet. #>
    param(
        [Parameter(Mandatory)][string]$Task,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$JobDir,
        [switch]$Deep,
        [switch]$NoKb,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Searcher = { param($q) Invoke-RealEvidenceSearch -Query $q },
        [scriptblock]$Dispatcher
    )
    $dispatch = {
        param($cand, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $cand $prompt) }
        return Invoke-Fleet -Name $cand.name -Prompt $prompt -Path $FleetPath -NoJournal
    }

    # 1. Assemble evidence (no model spend yet).
    $registry = Get-ToolsRegistrySummary -Path $ToolsPath
    $ensemble = Get-EnsembleSynthesis -JobDir $JobDir
    $kb = @()
    if (-not $NoKb) {
        try { $kb = @(Invoke-KbSearch -Query $Task -K 3 -SnippetChars 600) } catch { $kb = @() }
    }
    $search = Invoke-EvidenceSearch -Query $Task -Searcher $Searcher -Deep:$Deep

    # 2. Route + dispatch the cheapest research-capable worker.
    $cands = Select-Capability -Capability research -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) {
        return (New-GateFallback -Reason 'no research-capable worker available')
    }
    $prompt = Build-GatePrompt -TaskText $Task -RegistryLines $registry -EnsembleText $ensemble -KbHits $kb -SearchEvidence $search
    $pick = $cands[0]
    $res  = & $dispatch $pick $prompt
    if ([int]$res.exit_code -ne 0) { return (New-GateFallback -Reason "dispatch exit $([int]$res.exit_code)") }
    $verdict = ConvertTo-GateHashtable -RawStdout ([string]$res.stdout)
    if ($null -eq $verdict) { return (New-GateFallback -Reason 'model returned no valid JSON') }

    # 3. Escalate on low confidence / high risk / inconclusive.
    if (Test-GateEscalationNeeded -Verdict $verdict) {
        $champs = Select-Capability -Capability research -MaxCostTier $MaxCostTier -SelectionMode champion -FleetPath $FleetPath -ToolsPath $ToolsPath
        $esc = @($champs | Where-Object { $_.name -ne $pick.name }) | Select-Object -First 1
        if ($esc) {
            $res2 = & $dispatch $esc $prompt
            if ([int]$res2.exit_code -eq 0) {
                $verdict2 = ConvertTo-GateHashtable -RawStdout ([string]$res2.stdout)
                if ($null -ne $verdict2) {
                    $verdict2['escalated'] = $true
                    $verdict2['escalated_from'] = $pick.name
                    return $verdict2
                }
            }
        }
    }
    return $verdict
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: PASS — 34 checks.

- [ ] **Step 5: Commit**

```bash
git add scripts/research-gate-lib.ps1 scripts/test-research-gate.ps1
git commit -m "feat(research-gate): governed orchestration + escalation (T27-T34)"
```

---

### Task 5: CLI, slash command, seed capability

**Files:**
- Create: `scripts/fleet-research-gate.ps1`
- Create: `commands/research-gate.md`
- Modify: `references/fleet.yaml` (add `research` capability to `claude-haiku` and `claude-sonnet`)
- Modify: `scripts/test-research-gate.ps1` (append CLI child-process checks)

**Interfaces:**
- Consumes: `Invoke-ResearchGate`, `Format-GateMemo`, `Read-CurrentJob` (job-lib), `Get-BatonHome`.
- CLI params: `-Url`, `-File`, `-Text`, `-Deep`, `-Json`, `-Out <path>`, `-MaxCostTier`, plus env test seams `BATON_RG_TEST_JSON` (canned dispatcher), `BATON_RG_TEST_FLEET`, `BATON_RG_TEST_TOOLS`.

- [ ] **Step 1: Add the `research` capability to the seed** (`references/fleet.yaml`)

Change the `claude-haiku` capabilities line from:

```yaml
    capabilities: [triage, classify, summarize-short]
```

to:

```yaml
    capabilities: [triage, classify, research, summarize-short]
```

Change the `claude-sonnet` capabilities line from:

```yaml
    capabilities: [triage, code-gen, reasoning, summarize]
```

to:

```yaml
    capabilities: [triage, research, code-gen, reasoning, summarize]
```

(Box-private note already in the file header — no real inventory added; only capability tags on existing placeholder providers. Haiku is the cheap floor; champion mode reaches Sonnet.)

- [ ] **Step 2: Create the CLI** (`scripts/fleet-research-gate.ps1`)

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:research-gate runner. Resolves the task (url/file/text), produces a
  build/adopt/adapt/inconclusive verdict via the governed fleet, and writes the
  memo — to the active job's research phase when one is active, else stdout.
.NOTES
  Recommend-only. Reads the latest research ensemble synthesis as evidence.
#>
param(
    [string]$Url,
    [string]$File,
    [string]$Text,
    [switch]$Deep,
    [switch]$Json,
    [string]$Out,
    [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$ToolsPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'tools.yaml' } else { Join-Path $HOME '.baton/tools.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'research-gate-lib.ps1')
. (Join-Path $PSScriptRoot 'job-lib.ps1')

# Resolve task text from exactly one of -Url / -File / -Text.
$sources = @($Url, $File, $Text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($sources.Count -ne 1) { Write-Error "Provide exactly one of -Url, -File, or -Text."; exit 2 }
if ($Url)      { $task = (& gh issue view $Url --json title,body --jq '"# " + .title + "\n\n" + .body' 2>&1 | Out-String).Trim() }
elseif ($File) { if (-not (Test-Path $File)) { Write-Error "Input file not found: $File"; exit 2 }; $task = (Get-Content -LiteralPath $File -Raw).Trim() }
else           { $task = $Text.Trim() }

# Test seam: a canned dispatcher injected via env so the suite never calls a model.
if ($env:BATON_RG_TEST_FLEET) { $FleetPath = $env:BATON_RG_TEST_FLEET }
if ($env:BATON_RG_TEST_TOOLS) { $ToolsPath = $env:BATON_RG_TEST_TOOLS }
$dispatcher = $null
if ($env:BATON_RG_TEST_JSON) {
    $canned = $env:BATON_RG_TEST_JSON
    $dispatcher = { param($c,$p) @{ stdout = $canned; stderr=''; exit_code = 0; duration_s = 1 } }
}

# Resolve the active job's research phase (if any).
$jobDir = $null
$state = Read-CurrentJob
if ($state.job_id) { $jobDir = Join-Path (Get-BatonHome) "jobs/$($state.job_id)" }

$gateArgs = @{ Task = $task; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
if ($jobDir) { $gateArgs['JobDir'] = $jobDir }
if ($Deep)   { $gateArgs['Deep']   = $true }
if ($dispatcher) { $gateArgs['Dispatcher'] = $dispatcher; $gateArgs['NoKb'] = $true }
$verdict = Invoke-ResearchGate @gateArgs

$memo = Format-GateMemo -Verdict $verdict
$jsonOut = $verdict | ConvertTo-Json -Depth 6

if ($jobDir) {
    $ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
    $dst = Join-Path $jobDir "phases/research"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Set-Content -Path (Join-Path $dst "gate-$ts.md")   -Value $memo    -Encoding utf8NoBOM
    Set-Content -Path (Join-Path $dst "gate-$ts.json") -Value $jsonOut -Encoding utf8NoBOM
    Write-Host "Verdict written to phases/research/gate-$ts.md"
}
if ($Out) { Set-Content -Path $Out -Value $(if ($Json) { $jsonOut } else { $memo }) -Encoding utf8NoBOM; Write-Host "Wrote $Out" }
if ($Json) { $jsonOut } elseif (-not $jobDir -and -not $Out) { Write-Host $memo } elseif (-not $Out) { Write-Host $memo }
```

- [ ] **Step 3: Create the slash command** (`commands/research-gate.md`)

```markdown
---
description: Research Gate — build/adopt/adapt verdict before non-trivial work. Grounds a cheap governed-fleet model in real evidence (local registry + prior ensemble + KB + optional --deep live search). Recommend-only.
argument-hint: (--text "<task>" | --url <issue> | --file <path>) [--deep] [--json] [--out PATH]
---

# /baton:research-gate

Run the Research Gate over a task and emit a build/adopt/adapt/inconclusive verdict.
With an active job, the memo writes to that job's `phases/research/`; otherwise it
prints to stdout. Reads the latest research ensemble `synthesis.md` as evidence.

Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-research-gate.ps1" $ARGUMENTS
```

## Arguments

$ARGUMENTS
```

- [ ] **Step 4: Write the failing CLI test** (append before `finally` in `test-research-gate.ps1`)

```powershell
    # ---- Task 5: CLI (child process; zero network) ----
    $cli = Join-Path $PSScriptRoot 'fleet-research-gate.ps1'
    $env:BATON_RG_TEST_JSON  = $adoptReply
    $env:BATON_RG_TEST_FLEET = $tmpFleet
    $env:BATON_RG_TEST_TOOLS = $tmpTools
    $env:BATON_HOME = $tmpDir   # no current-job.json here -> standalone path
    $stdout = & pwsh -NoProfile -File $cli -Text 'convert pdfs to markdown' 2>&1 | Out-String
    Check 'T35 CLI standalone prints memo to stdout' ($stdout -match 'RESEARCH GATE' -and $stdout -match 'ADOPT')
    $jsonStdout = & pwsh -NoProfile -File $cli -Text 'x' -Json 2>&1 | Out-String
    Check 'T36 CLI --json emits json' ($jsonStdout -match '"recommendation"')
    $outFile = Join-Path $tmpDir 'memo.md'
    & pwsh -NoProfile -File $cli -Text 'x' -Out $outFile 2>&1 | Out-Null
    Check 'T37 CLI --out writes file' ((Test-Path $outFile) -and ((Get-Content $outFile -Raw) -match 'RESEARCH GATE'))

    # Active-job path: writes into phases/research/
    $jobId = 'rgjob'
    $jobHome = Join-Path $tmpDir 'jobhome'
    New-Item -ItemType Directory -Force -Path (Join-Path $jobHome "jobs/$jobId") | Out-Null
    Set-Content -Path (Join-Path $jobHome 'current-job.json') -Value (@{ job_id=$jobId; phase='research' } | ConvertTo-Json) -Encoding utf8NoBOM
    $env:BATON_HOME = $jobHome
    & pwsh -NoProfile -File $cli -Text 'convert pdfs' 2>&1 | Out-Null
    $gateFiles = Get-ChildItem -Path (Join-Path $jobHome "jobs/$jobId/phases/research") -Filter 'gate-*.md' -ErrorAction SilentlyContinue
    Check 'T38 CLI within a job writes gate memo to research phase' (@($gateFiles).Count -ge 1)
    Remove-Item Env:\BATON_RG_TEST_JSON, Env:\BATON_RG_TEST_FLEET, Env:\BATON_RG_TEST_TOOLS, Env:\BATON_HOME -ErrorAction SilentlyContinue
```

Also add temp-dir cleanup in the `finally` block (if not already present):

```powershell
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
```

- [ ] **Step 5: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: PASS — 38 checks. (Child-process CLI runs offline via the canned dispatcher; zero network.)

- [ ] **Step 6: Commit**

```bash
git add scripts/fleet-research-gate.ps1 commands/research-gate.md references/fleet.yaml scripts/test-research-gate.ps1
git commit -m "feat(research-gate): CLI + /baton:research-gate + research capability seed (T35-T38)"
```

---

### Task 6: Deployment wiring

**Files:**
- Modify: `scripts/bootstrap.ps1:259` (manifest array)
- Modify: `scripts/test-bootstrap.ps1` (two deploy assertions)
- Modify: `.claude-plugin/plugin.json` (version bump)

**Interfaces:** none (packaging only).

- [ ] **Step 1: Add the two scripts to the bootstrap manifest**

In `scripts/bootstrap.ps1`, in the `foreach ($script in @(...))` deploy array (the line containing `'projects-lib.ps1', 'fleet-projects.ps1'`), add after `'fleet-projects.ps1',`:

```powershell
'research-gate-lib.ps1', 'fleet-research-gate.ps1',
```

- [ ] **Step 2: Add deploy assertions to the bootstrap test**

In `scripts/test-bootstrap.ps1`, after the lines:

```powershell
Assert "deploys projects-lib script"   ($out -match 'projects-lib\.ps1')
Assert "deploys fleet-projects script" ($out -match 'fleet-projects\.ps1')
```

add:

```powershell
Assert "deploys research-gate-lib script"   ($out -match 'research-gate-lib\.ps1')
Assert "deploys fleet-research-gate script" ($out -match 'fleet-research-gate\.ps1')
```

- [ ] **Step 3: Bump the plugin version** (`.claude-plugin/plugin.json`)

Change `"version": "1.2.0-rc.10",` to `"version": "1.2.0-rc.11",`.

- [ ] **Step 4: Run the bootstrap smoke test**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS on the two new asserts (and no regressions). Dry-run; writes nothing.

- [ ] **Step 5: Run the full research-gate suite once more**

Run: `pwsh -NoProfile -File scripts/test-research-gate.ps1`
Expected: PASS — 38 checks.

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "build(research-gate): deploy manifest + bootstrap asserts + plugin rc.11"
```

---

## Self-Review

**Spec coverage:**
- §1 scope / gather-vs-decide split → Tasks 2 (`Get-EnsembleSynthesis`), 4, 5. ✓
- §2 d-rg-1 reads ensemble → T16/T17 + CLI JobDir. ✓ d-rg-2 cheap floor + `-Deep` + escalation → T27–T34, seed (Task 5 step 1). ✓ d-rg-3 build/adopt/adapt/inconclusive advisory → schema (Task 2), fallback (T11–T13). ✓ d-rg-4 two seams hermetic → `-Searcher`/`-Dispatcher`, all tests stubbed. ✓ d-rg-5 job-phase + standalone → T35–T38. ✓ d-rg-6 box-private → seed note (Task 5 step 1), Global Constraints. ✓
- §3 verdict schema → `Build-GatePrompt` (T20), `ConvertTo-GateHashtable`. ✓
- §4 every named function has a task. ✓
- §5 data flow order (evidence → route → dispatch → escalate → output) → `Invoke-ResearchGate` + CLI. ✓
- §6 error handling: no worker (T32), unparseable (T31/T6), searcher throw (T26), no job (T35), no ensemble (T17), KB guarded (`-NoKb` + try/catch). ✓
- §8 ~24 checks → 38 checks. ✓ Bootstrap deploy asserts → Task 6. ✓

**Placeholder scan:** none — every code step shows complete code. ✓

**Type consistency:** `Invoke-ResearchGate` consumes `Build-GatePrompt`/`Get-ToolsRegistrySummary`/`Get-EnsembleSynthesis`/`Invoke-EvidenceSearch`/`ConvertTo-GateHashtable`/`Test-GateEscalationNeeded`/`New-GateFallback` with the exact signatures Tasks 1–3 define. CLI consumes `Invoke-ResearchGate`/`Format-GateMemo` as defined. Verdict hashtable keys (`recommendation`, `options`, `rationale`, `next_action`, `confidence`, `risk_if_wrong`, `escalated`, `escalated_from`, `escalation_needed`) are consistent across parse, escalate, format, fallback. ✓
