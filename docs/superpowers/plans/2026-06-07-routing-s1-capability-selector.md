# Routing Slice 1 — Capability Selector + Data Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a PowerShell capability selector (`Select-Capability`) over `tools.yaml` + `fleet.yaml` that returns an explainable, cheapest-tier-first ranked candidate list, surfaced via `/route`, after migrating capability-specific models into `tools.yaml`.

**Architecture:** `routing-lib.ps1` reuses `fleet-lib.ps1`'s `Read-Fleet` and adds `Read-Tools` (hand-rolled flat YAML parser, same pattern), `Get-GeneralCapabilities`/`Get-KnownCapabilities` (inline-list parse, like `Get-FleetResearchDefault`), and `Select-Capability` (candidate gather → filter → rank). `/route` shows the recommendation; no dispatch (that is Slice 2).

**Tech Stack:** PowerShell 7 (pwsh); YAML registries; the project PS test harness.

**Spec:** `docs/superpowers/specs/2026-06-07-routing-s1-capability-selector-design.md`

---

## Conventions (read once)

- **PS test harness:** define `function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }`; `$script:fail = 0` up top; temp fixtures under `[System.IO.Path]::GetTempPath()`; wrap body in `try { … } finally { Remove-Item -Recurse -Force $tmp }`; end with `if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }`.
- **Run a suite:** `pwsh -NoProfile -File scripts/test-routing-lib.ps1`.
- **Array return idiom:** `return ,([object[]]$x)` so a 0/1-element result never unrolls to `$null`/scalar.
- **`Read-Tools` mirrors `Read-Fleet`** in `scripts/fleet-lib.ps1` but tools.yaml is FLAT (no `env:` blocks) — drop the env handling. Reuse `ConvertFrom-FleetValue` (dot-source `fleet-lib.ps1` from `routing-lib.ps1`).
- **`Get-GeneralCapabilities`** mirrors `Get-FleetResearchDefault` (regex an inline `key: [a, b, c]` list).
- **Cost-tier rank:** `local`=0, `free`=1, `paid`=2 (cheapest first). **Quality** is unrated in Slice 1 → treat as a neutral middle (`0.5` on a 0..1 scale) so it never outranks a known-good and never sinks below a known-bad.
- **Bootstrap:** libs deploy array is ~line 250; commands array ~line 232. Smoke (`test-bootstrap.ps1`) runs DRY-RUN → assert against STDOUT (`$out -match`), never `Test-Path`.
- Do NOT implement dispatch, grading, escalation, ratings, calibration, or real quality scoring — those are Slices 2–3.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/routing-lib.ps1` (create) | `Read-Tools`, `Get-GeneralCapabilities`, `Get-KnownCapabilities`, `Select-Capability`. |
| `scripts/test-routing-lib.ps1` (create) | Unit tests for the above. |
| `references/tools.yaml` (modify) | Add `git-commit-message`/`nuextract`/`deepseek-ocr` `kind:cli` entries. |
| `references/fleet.yaml` (modify) | Add top-level `general_capabilities: [code-gen, reasoning, summarize]`. |
| `commands/route.md` (create) | `/route <capability> [--max-tier] [--local]` recommendation prompt. |
| `knowledge/universal/routing.md` (modify, in `~/.claude/` AND note for the seed) | Repoint specialty-models prose to `tools.yaml` + `/route`. |
| `scripts/bootstrap.ps1` (modify) | Deploy `routing-lib.ps1` (libs array) + `route.md` (commands array). |
| `scripts/test-bootstrap.ps1` (modify) | Dry-run stdout assertions for the two new files. |

> **Note on `routing.md`:** it lives at `~/.claude/knowledge/universal/routing.md` (a deployed/runtime file, also a git-tracked file in the `Ryfter/knowledge` repo), NOT in this repo. Task 6 edits it in place; there is no repo seed to change. Keep that edit minimal and commit it in the knowledge repo separately (the orchestrator repo has no copy).

---

### Task 1: `Read-Tools` parser

**Files:**
- Create: `scripts/routing-lib.ps1`
- Create: `scripts/test-routing-lib.ps1`

- [ ] **Step 1: Write the failing test**

Create `scripts/test-routing-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # --- Fixtures ---
    $toolsYaml = @"
tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
  - name: git-commit-message
    kind: cli
    enabled: true
    cost_tier: local
    capability: commit-msg
    command_template: 'ollama run tavernari/git-commit-message'
    stdin: true
  - name: paid-ocr
    kind: cli
    enabled: true
    cost_tier: paid
    capability: ocr
    command_template: 'cloudocr {{prompt}}'
  - name: local-ocr
    kind: cli
    enabled: true
    cost_tier: local
    capability: ocr
    command_template: 'ollama run deepseek-ocr'
  - name: off-tool
    kind: cli
    enabled: false
    cost_tier: local
    capability: commit-msg
    command_template: 'ollama run something'
"@
    $toolsPath = Join-Path $tmp 'tools.yaml'
    Set-Content -Path $toolsPath -Value $toolsYaml -Encoding utf8

    $fleetYaml = @"
research_default: [claude-cli, codex]
general_capabilities: [code-gen, reasoning, summarize]

providers:
  - name: claude-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'claude -p "{{prompt}}"'
  - name: ollama-local
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'ollama run devstral:24b "{{prompt}}"'
  - name: off-model
    kind: cli
    enabled: false
    cost_tier: local
    command_template: 'ollama run x "{{prompt}}"'
"@
    $fleetPath = Join-Path $tmp 'fleet.yaml'
    Set-Content -Path $fleetPath -Value $fleetYaml -Encoding utf8

    # --- Task 1: Read-Tools ---
    $tools = Read-Tools -Path $toolsPath
    Check 'reads 5 tools'              ($tools.Count -eq 5)
    $gcm = $tools | Where-Object { $_.name -eq 'git-commit-message' }
    Check 'capability parsed'          ($gcm.capability -eq 'commit-msg')
    Check 'cost_tier parsed'           ($gcm.cost_tier -eq 'local')
    Check 'kind parsed'                ($gcm.kind -eq 'cli')
    Check 'stdin parsed bool'          ($gcm.stdin -eq $true)
    Check 'command_template parsed'    ($gcm.command_template -eq 'ollama run tavernari/git-commit-message')
    Check 'enabled bool'              (($tools | Where-Object { $_.name -eq 'off-tool' }).enabled -eq $false)
}
finally { if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp } }
if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: FAIL — `routing-lib.ps1` does not exist / `Read-Tools` not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/routing-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing selector (Slice 1). Reads tools.yaml + fleet.yaml and ranks
  the candidates that can serve a capability, cheapest cost-tier first.
.DESCRIPTION
  Recommendation only — no dispatch (Slice 2) and no learned quality (Slice 3).
  See docs/superpowers/specs/2026-06-07-routing-s1-capability-selector-design.md.
#>

. "$PSScriptRoot/fleet-lib.ps1"   # for Read-Fleet + ConvertFrom-FleetValue

$script:DefaultToolsPath = (Join-Path $HOME '.claude/tools.yaml')

function Read-Tools {
    <# Parse tools.yaml into an array of tool hashtables. Flat schema (no env blocks). #>
    param([string]$Path = $script:DefaultToolsPath)
    if (-not (Test-Path $Path)) {
        throw "tools.yaml not found at $Path. Run scripts/bootstrap.ps1 to deploy the seed."
    }
    $tools = [System.Collections.ArrayList]@()
    $current = $null
    foreach ($rawLine in (Get-Content $Path)) {
        if ($rawLine -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        if ($rawLine -match '^tools:\s*$') { continue }
        if ($rawLine -match '^(\s*)-\s+name:\s*(.+?)\s*$') {
            if ($current) { [void]$tools.Add($current) }
            $current = @{ name = (ConvertFrom-FleetValue $matches[2]) }
            continue
        }
        if (-not $current) { continue }
        if ($rawLine -match '^\s+([\w.-]+):\s*(.*?)\s*$') {
            $current[$matches[1]] = (ConvertFrom-FleetValue $matches[2])
        }
    }
    if ($current) { [void]$tools.Add($current) }
    return $tools.ToArray()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: PASS (7 Read-Tools checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-lib.ps1 scripts/test-routing-lib.ps1
git commit -m "feat(routing): Read-Tools yaml parser"
```

---

### Task 2: Data model — tools.yaml specialty entries + fleet.yaml general_capabilities

**Files:**
- Modify: `references/tools.yaml`
- Modify: `references/fleet.yaml`

- [ ] **Step 1: Add the specialty tool entries**

Append to the `tools:` list in `references/tools.yaml` (after the `docling` entry):

```yaml
  - name: git-commit-message
    kind: cli
    enabled: true
    cost_tier: local
    capability: commit-msg
    command_template: 'ollama run tavernari/git-commit-message'
    stdin: true            # the staged diff is piped in
  - name: nuextract
    kind: cli
    enabled: true
    cost_tier: local
    capability: struct-extract
    command_template: 'ollama run nuextract'
  - name: deepseek-ocr
    kind: cli
    enabled: true
    cost_tier: local
    capability: ocr
    command_template: 'ollama run deepseek-ocr'
```

- [ ] **Step 2: Declare general capabilities in fleet.yaml**

In `references/fleet.yaml`, add this line directly below the existing `research_default:` line:

```yaml
# Broad capabilities served by the general (conversational) models below.
# The router treats every ENABLED provider as a candidate for these.
general_capabilities: [code-gen, reasoning, summarize]
```

- [ ] **Step 3: Verify both parse**

Run:
```powershell
pwsh -NoProfile -Command ". scripts/routing-lib.ps1; (Read-Tools -Path references/tools.yaml).name; '---'; Get-FleetResearchDefault -Path references/fleet.yaml"
```
Expected: lists `docling`, `git-commit-message`, `nuextract`, `deepseek-ocr` (and any others present), then `---`, then `claude-cli codex …` (proves fleet.yaml still parses with the new key present).

- [ ] **Step 4: Confirm the Python tools tests still pass (unknown keys ignored)**

Run: `python -m pytest tools -q`
Expected: PASS — the Python reader ignores `stdin`/extra keys; unit tests use fixtures, not `references/tools.yaml`.

- [ ] **Step 5: Commit**

```bash
git add references/tools.yaml references/fleet.yaml
git commit -m "feat(routing): migrate specialty models into tools.yaml; declare general_capabilities"
```

---

### Task 3: `Get-GeneralCapabilities` + `Get-KnownCapabilities`

**Files:**
- Modify: `scripts/routing-lib.ps1`
- Modify: `scripts/test-routing-lib.ps1`

- [ ] **Step 1: Write the failing test**

Add to `scripts/test-routing-lib.ps1` inside the `try` block, after the Read-Tools checks:

```powershell
    # --- Task 3: capability vocab ---
    $gc = Get-GeneralCapabilities -FleetPath $fleetPath
    Check 'general caps count'         ($gc.Count -eq 3)
    Check 'general caps has code-gen'  ($gc -contains 'code-gen')
    Check 'general caps absent = empty' ((Get-GeneralCapabilities -FleetPath $toolsPath).Count -eq 0)

    $known = Get-KnownCapabilities -ToolsPath $toolsPath -FleetPath $fleetPath
    Check 'known has tool cap'         ($known -contains 'commit-msg')
    Check 'known has general cap'      ($known -contains 'reasoning')
    Check 'known is deduped'           (($known | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: FAIL — `Get-GeneralCapabilities` not recognized.

- [ ] **Step 3: Write the implementation**

Append to `scripts/routing-lib.ps1`:

```powershell
function Get-GeneralCapabilities {
    <# Read the top-level `general_capabilities: [a, b, c]` inline list from fleet.yaml.
       Returns string[] (empty if the key is absent). Mirrors Get-FleetResearchDefault. #>
    param([string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'))
    if (-not (Test-Path $FleetPath)) { return @() }
    foreach ($line in (Get-Content $FleetPath)) {
        if ($line -match '^\s*general_capabilities:\s*\[(.*)\]\s*$') {
            $inner = $matches[1].Trim()
            if (-not $inner) { return @() }
            return @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
        }
    }
    return @()
}

function Get-KnownCapabilities {
    <# Union of every tools.yaml capability + fleet.yaml general_capabilities. #>
    param(
        [string]$ToolsPath = $script:DefaultToolsPath,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml')
    )
    $caps = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $ToolsPath) {
        foreach ($t in (Read-Tools -Path $ToolsPath)) {
            if ($t.capability) { [void]$caps.Add([string]$t.capability) }
        }
    }
    foreach ($g in (Get-GeneralCapabilities -FleetPath $FleetPath)) { [void]$caps.Add($g) }
    return @($caps | Select-Object -Unique)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: PASS (Read-Tools + 6 new checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-lib.ps1 scripts/test-routing-lib.ps1
git commit -m "feat(routing): capability vocabulary (general + known)"
```

---

### Task 4: `Select-Capability` (gather → filter → rank)

**Files:**
- Modify: `scripts/routing-lib.ps1`
- Modify: `scripts/test-routing-lib.ps1`

- [ ] **Step 1: Write the failing test**

Add to `scripts/test-routing-lib.ps1` inside the `try` block, after the Task 3 checks:

```powershell
    # --- Task 4: Select-Capability ---
    $common = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath }

    # specialized capability → the one enabled tool, source=tools
    $cm = Select-Capability -Capability 'commit-msg' @common
    Check 'commit-msg one candidate'   ($cm.Count -eq 1)
    Check 'commit-msg picks tool'      ($cm[0].name -eq 'git-commit-message')
    Check 'commit-msg source tools'    ($cm[0].source -eq 'tools')
    Check 'commit-msg has why'         ([bool]$cm[0].why)
    Check 'disabled tool excluded'     (-not ($cm | Where-Object { $_.name -eq 'off-tool' }))

    # cheapest-tier-first: ocr has a local and a paid tool → local first
    $ocr = Select-Capability -Capability 'ocr' @common
    Check 'ocr two candidates'         ($ocr.Count -eq 2)
    Check 'ocr local ranks first'      ($ocr[0].name -eq 'local-ocr')
    Check 'ocr paid ranks last'        ($ocr[1].name -eq 'paid-ocr')

    # general capability → enabled fleet providers, source=fleet, cheapest first
    $cg = Select-Capability -Capability 'code-gen' @common
    Check 'code-gen from fleet'        ($cg[0].source -eq 'fleet')
    Check 'code-gen local first'       ($cg[0].name -eq 'ollama-local')
    Check 'code-gen excludes disabled' (-not ($cg | Where-Object { $_.name -eq 'off-model' }))

    # constraints
    $cgLocal = Select-Capability -Capability 'code-gen' -RequireLocal @common
    Check 'RequireLocal drops paid'    (-not ($cgLocal | Where-Object { $_.cost_tier -eq 'paid' }))
    $ocrFree = Select-Capability -Capability 'ocr' -MaxCostTier 'free' @common
    Check 'MaxCostTier free drops paid' (-not ($ocrFree | Where-Object { $_.cost_tier -eq 'paid' }))

    # unknown capability → empty
    $none = Select-Capability -Capability 'nonexistent' @common
    Check 'unknown cap empty'          ($none.Count -eq 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: FAIL — `Select-Capability` not recognized.

- [ ] **Step 3: Write the implementation**

Append to `scripts/routing-lib.ps1`:

```powershell
function Get-CostTierRank([string]$Tier) {
    switch ($Tier) {
        'local' { return 0 }
        'free'  { return 1 }
        'paid'  { return 2 }
        default { return 3 }   # unknown tiers sort last
    }
}

function Select-Capability {
    <# Return ranked candidates (tools + general models) that serve a capability.
       Cheapest cost-tier first; quality is unrated in Slice 1 (neutral 0.5).
       Recommendation only — no dispatch. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [switch]$RequireLocal,
        [string]$ToolsPath = $script:DefaultToolsPath,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml')
    )
    $candidates = [System.Collections.ArrayList]@()

    # 1. Specialized candidates from tools.yaml
    if (Test-Path $ToolsPath) {
        foreach ($t in (Read-Tools -Path $ToolsPath)) {
            if ($t.enabled -ne $true) { continue }
            if ([string]$t.capability -ne $Capability) { continue }
            $q = if ($null -ne $t.quality) { [double]$t.quality } else { 0.5 }
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$t.name; kind = [string]$t.kind; source = 'tools'
                cost_tier = [string]$t.cost_tier; quality = $q
                why = "specialized tool for $Capability ($($t.cost_tier))"
            })
        }
    }

    # 2. General candidates from fleet.yaml when the capability is a general one
    $general = Get-GeneralCapabilities -FleetPath $FleetPath
    if ($general -contains $Capability -and (Test-Path $FleetPath)) {
        foreach ($p in (Read-Fleet -Path $FleetPath)) {
            if ($p.enabled -ne $true) { continue }
            $q = if ($null -ne $p.quality) { [double]$p.quality } else { 0.5 }
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$p.name; kind = [string]$p.kind; source = 'fleet'
                cost_tier = [string]$p.cost_tier; quality = $q
                why = "general model for $Capability ($($p.cost_tier) tier)"
            })
        }
    }

    # 3. Filter by constraints
    $filtered = foreach ($c in $candidates) {
        if ($RequireLocal -and $c.cost_tier -ne 'local') { continue }
        if ($MaxCostTier -and (Get-CostTierRank $c.cost_tier) -gt (Get-CostTierRank $MaxCostTier)) { continue }
        $c
    }

    # 4. Rank: cost tier asc, then quality desc, then name. Attach a numeric score.
    $ranked = $filtered |
        Select-Object *, @{n='score'; e={ (Get-CostTierRank $_.cost_tier) - ($_.quality * 0.001) }} |
        Sort-Object @{e='score'}, @{e={ -$_.quality }}, @{e='name'}
    return ,([object[]]$ranked)
}
```

> **Why the score formula:** `cost_tier_rank - quality*0.001` keeps cost tier dominant (ranks
> differ by ≥1) while letting quality break ties within a tier (the `Sort-Object` secondary key
> `-quality` makes higher quality sort earlier). Unrated `0.5` sits between any known-good (→1)
> and known-bad (→0), so it never overtakes a proven candidate nor sinks below a poor one.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: PASS (all prior + 15 Select-Capability checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-lib.ps1 scripts/test-routing-lib.ps1
git commit -m "feat(routing): Select-Capability ranked cheapest-tier-first selector"
```

---

### Task 5: `/route` command-prompt

**Files:**
- Create: `commands/route.md`

- [ ] **Step 1: Write the command-prompt**

Create `commands/route.md`:

```markdown
---
description: Recommend the optimal capability (tool or model) for a need — cheapest capable tier first ("optimal, not best"), reading tools.yaml + fleet.yaml. Slice 1 recommends; it does not dispatch (that is the auto-router, a later slice).
argument-hint: "<capability>" [--max-tier local|free|paid] [--local]
---

# /route

Recommend the optimal capability for a need. Reads the `tools.yaml` (capability-specific tools
+ specialty models) and `fleet.yaml` (general models) registries and ranks the candidates that
serve `<capability>`, cheapest cost-tier first. **Recommendation only** — dispatch is manual
until the auto-router slice lands.

## Steps

1. **Parse `$ARGUMENTS`:** the first token is `<capability>` (e.g. `commit-msg`, `ocr`,
   `code-gen`); optional `--max-tier local|free|paid` and `--local`. Empty capability → stop
   with: *"Usage: /route \"<capability>\" [--max-tier local|free|paid] [--local]"*.

2. **Select candidates:**

   ```powershell
   . "$HOME/.claude/scripts/routing-lib.ps1"
   $sel = @{ Capability = '<capability>' }
   if ($local)   { $sel['RequireLocal'] = $true }
   if ($maxTier) { $sel['MaxCostTier']  = '<tier>' }
   $cands = Select-Capability @sel
   ```

3. **Report:**
   - If `$cands` is empty, tell the user no candidate serves `<capability>` and list the known
     ones:

     ```powershell
     Get-KnownCapabilities
     ```

   - Otherwise print the ranked table and state the top pick:

     ```powershell
     $cands | Format-Table name, source, kind, cost_tier, quality, why -AutoSize
     Write-Host "Top pick: $($cands[0].name) — $($cands[0].why)"
     ```

   Note to the user that this is a recommendation; dispatch is manual until the auto-router slice.

4. **On any error** (missing `tools.yaml`/`fleet.yaml`), surface the thrown message and suggest
   `pwsh scripts\bootstrap.ps1 -Force` to deploy the registries.

## Arguments

$ARGUMENTS
```

- [ ] **Step 2: Smoke the backend it calls**

Run:
```powershell
pwsh -NoProfile -Command ". scripts/routing-lib.ps1; Select-Capability -Capability 'commit-msg' -ToolsPath references/tools.yaml -FleetPath references/fleet.yaml | Format-Table name, source, cost_tier, why"
```
Expected: a one-row table for `git-commit-message` (source `tools`, `local`).

- [ ] **Step 3: Commit**

```bash
git add commands/route.md
git commit -m "feat(routing): /route recommendation command-prompt"
```

---

### Task 6: Repoint `routing.md`

**Files:**
- Modify: `~/.claude/knowledge/universal/routing.md` (knowledge repo, not this repo)

- [ ] **Step 1: Replace the specialty-models section**

In `~/.claude/knowledge/universal/routing.md`, replace the entire `## Specialty models (invoke directly via Bash, bypass Octopus)` section (and its three model subsections) with:

```markdown
## Specialty models → now in `tools.yaml`

The capability-specific models that used to be listed here (commit-message, structured
extraction, OCR) are now first-class entries in `~/.claude/tools.yaml`, alongside non-model
tools like Docling. Don't hand-pick them here — ask the router:

```
/route commit-msg      # → tavernari/git-commit-message (local)
/route struct-extract  # → nuextract (local)
/route ocr             # → deepseek-ocr (local)
/route pdf-extract     # → docling (local)
```

`/route <capability>` ranks every candidate (tool or model) cheapest-capable-tier first.
The general-coders catalog below is still the human reference for broad capabilities
(code-gen / reasoning / summarize) and the future home of learned quality notes.
```

Leave the `## General coders` section and everything after it unchanged.

- [ ] **Step 2: Commit (in the knowledge repo)**

```powershell
$kb = Join-Path $HOME '.claude/knowledge'
git -C $kb add universal/routing.md
git -C $kb commit -m "docs(routing): repoint specialty models to tools.yaml + /route"
```

(Push happens with the rest of the knowledge-repo backup at slice closeout.)

---

### Task 7: Bootstrap deploy + smoke

**Files:**
- Modify: `scripts/bootstrap.ps1`
- Modify: `scripts/test-bootstrap.ps1`

- [ ] **Step 1: Write the failing smoke assertions**

In `scripts/test-bootstrap.ps1`, next to the existing `tools.yaml`/`tools.md` assertions, add:

```powershell
Assert "would deploy routing-lib.ps1"     ($out -match 'routing-lib\.ps1')
Assert "would deploy route.md"            ($out -match 'route\.md')
```

- [ ] **Step 2: Run the smoke to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — the two new assertions fail.

- [ ] **Step 3: Modify bootstrap**

(a) In `scripts/bootstrap.ps1`, add `'routing-lib.ps1'` to the libs deploy array (~line 250, the `foreach ($script in @(...))` list). Add it after `'fleet-ensemble.ps1'`:

```powershell
'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1', 'routing-lib.ps1', 'six-hats-lib.ps1',
```

(b) Add `'route.md'` to the commands array (~line 232), after `'tools.md'`:

```powershell
    'fleet.md','ensemble.md','research.md','six-hats.md','council.md','idea.md','tools.md','route.md',
```

- [ ] **Step 4: Run the smoke to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS (`ALL PASS`), including the two new assertions.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(routing): deploy routing-lib.ps1 + route.md via bootstrap"
```

---

## Final verification (after all tasks)

- [ ] **Routing suite:** `pwsh -NoProfile -File scripts/test-routing-lib.ps1` → `ALL PASS`.
- [ ] **Bootstrap smoke:** `pwsh -NoProfile -File scripts/test-bootstrap.ps1` → `ALL PASS`.
- [ ] **No regressions — Python:** `python -m pytest -q` → all pass.
- [ ] **No regressions — other PS suites:** run `test-idea-lib`, `test-run-feed-hook`, `test-statusline-feed`, `test-fleet-runs-bridge`, `test-runs-lib`, `test-fleet-backlog`, `test-fleet-backlog-concurrent` → all `ALL PASS`.
- [ ] **Live smoke:** with the repo registries, `Select-Capability -Capability 'code-gen' -FleetPath references/fleet.yaml -ToolsPath references/tools.yaml` ranks `ollama-local` above the paid providers.
- [ ] **Comprehensive review** (one final review per execution-style preference).

## Notes for the implementer

- `routing-lib.ps1` dot-sources `fleet-lib.ps1` for `Read-Fleet` + `ConvertFrom-FleetValue`; do not re-implement those.
- Slice 1 is recommendation-only. If you feel tempted to make `/route` actually invoke the pick — stop; that is Slice 2 (auto-dispatch + verify/escalate).
- `quality` is an unrated slot. Do not build a quality data source; Slice 3 owns it.
- `references/tools.yaml` is consumed by BOTH the new PS `Read-Tools` and the existing Python `tools/registry.py`. The new `stdin`/`quality` keys are ignored by Python — keep them; do not remove fields to please one reader.
- `routing.md` is a knowledge-repo file, committed there separately (Task 6) — the orchestrator repo has no copy to change.
