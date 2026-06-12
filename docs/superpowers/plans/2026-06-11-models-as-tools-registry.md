# Models-as-Tools Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-provider capability claims (with context floors, usage classes, keep-list), claims-based judge resolution, a `/baton:models` inventory command, and Gauntlet scorecard import into the ratings store.

**Architecture:** Additive fields on the existing hand-rolled fleet.yaml parser; `Select-Capability` becomes claims-aware with an economy/champion mode; `Get-JudgeModel` replaces the file-order judge pick; a new `fleet-models.ps1` probes LM Studio / ollama APIs with injectable probers; `Import-GauntletScorecard` feeds the existing Bayesian quality blend via a new `gauntlet` evidence bucket.

**Tech Stack:** PowerShell 7, line-oriented YAML parser (no module deps), JSONL stores, existing `Check`-style test suites.

**Branch:** `feat/models-as-tools-registry` (worktree-isolated; gated merge flow).
**Spec:** `docs/superpowers/specs/2026-06-11-models-as-tools-registry-design.md`.
**Standing rules:** tests NEVER touch real `~/.baton` / `~/.claude` — every path explicit under `$env:TEMP`; Kevin's execution style = skip per-task reviewers, ONE adversarial review in Task 7.

---

## File map

| File | Change |
|---|---|
| `scripts/fleet-lib.ps1` | inline-list values; top-level-key hardening; `Get-FleetKeepList` |
| `scripts/test-fleet-lib.ps1` | new asserts for the above |
| `scripts/routing-lib.ps1` | `Get-CapabilityFloors`; claims-aware + floor-filtered + `-SelectionMode` in `Select-Capability` |
| `scripts/test-routing-lib.ps1` | claims/floors/champion asserts |
| `scripts/routing-learn.ps1` | `Get-JudgeModel`; grader wiring; `Import-GauntletScorecard`; gauntlet bucket in stats/quality |
| `scripts/test-routing-learn.ps1` | judge resolution + import + blend asserts |
| `scripts/fleet-models.ps1` | NEW — inventory command engine |
| `scripts/test-fleet-models.ps1` | NEW — fixture-driven suite (injected probers) |
| `commands/models.md` | NEW — `/baton:models` |
| `references/fleet.yaml` | taxonomy docs, floors, keep_list, example claims |
| `scripts/fleet-doctor.ps1` | `class` column (usage_class) |
| `scripts/bootstrap.ps1` + `scripts/test-bootstrap.ps1` | deploy `fleet-models.ps1` |
| `.claude-plugin/plugin.json` | version 1.2.0-rc.7 |

---

### Task 1: fleet-lib.ps1 — inline-list values, top-level-key hardening, keep_list reader

**Files:**
- Modify: `scripts/fleet-lib.ps1` (Read-Fleet ~46–103; new function after `Get-FleetResearchDefault` ~126)
- Test: `scripts/test-fleet-lib.ps1` (append before the suite's exit/summary block — read the file first to find the harness pattern; it uses `Check($n,$c)` and a `$tmp` temp dir)

- [ ] **Step 1: Write failing tests.** Append to `scripts/test-fleet-lib.ps1` inside its try block (reuse its `$tmp`):

```powershell
    # ===== models-as-tools: inline lists, top-level hardening, keep_list =====
    $matYaml = @"
keep_list: ['*heretic*', '*swahili*']

providers:
  - name: big-local
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    capabilities: [code-gen, synthesize]
    context: 32768
    usage_class: broad

capability_floors:
  summarize-long: 65536
"@
    $matPath = Join-Path $tmp 'mat-fleet.yaml'
    Set-Content -Path $matPath -Value $matYaml -Encoding utf8
    $matProviders = Read-Fleet -Path $matPath
    $bl = $matProviders | Where-Object { $_.name -eq 'big-local' }
    Check 'inline list parses to array'      ($bl.capabilities -is [array] -and @($bl.capabilities).Count -eq 2 -and $bl.capabilities[1] -eq 'synthesize')
    Check 'scalar fields still parse'        ($bl.context -eq '32768' -and $bl.usage_class -eq 'broad')
    Check 'top-level key after providers not absorbed' (-not $bl.ContainsKey('summarize-long'))
    Check 'keep_list reader'                 (@(Get-FleetKeepList -Path $matPath).Count -eq 2 -and (Get-FleetKeepList -Path $matPath)[0] -eq '*heretic*')
    Check 'keep_list absent -> empty'        (@(Get-FleetKeepList -Path (Join-Path $tmp 'no-such.yaml')).Count -eq 0)
```

- [ ] **Step 2: Run to verify failures.** `pwsh -NoProfile -File scripts/test-fleet-lib.ps1` — Expected: FAILs for the new checks (list arrives as the string `[code-gen, synthesize]`; `summarize-long` absorbed into big-local; `Get-FleetKeepList` not defined).

- [ ] **Step 3: Implement.** Three edits in `scripts/fleet-lib.ps1`:

(a) In `Read-Fleet`, immediately AFTER the new-provider `- name:` match block (after its `continue`) and BEFORE `if (-not $current) { continue }`, add:

```powershell
        # A new top-level key (no indentation) ends the providers block — stop
        # absorbing indented children (e.g. capability_floors entries) into the
        # last provider. `providers:` itself is skipped above.
        if ($current -and $rawLine -match '^[\w.-]+:') {
            [void]$providers.Add($current)
            $current = $null
            $inEnv = $false
            continue
        }
```

(b) In the ordinary-field branch, replace `$current[$key] = (ConvertFrom-FleetValue $val)` with:

```powershell
            $parsed = ConvertFrom-FleetValue $val
            # Inline YAML list value: 'capabilities: [a, b]' -> string[].
            if ($parsed -is [string] -and $parsed -match '^\[(.*)\]$') {
                $inner = $matches[1].Trim()
                $parsed = if ($inner) {
                    @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
                } else { @() }
            }
            $current[$key] = $parsed
```

(c) After `Get-FleetResearchDefault`, add:

```powershell
function Get-FleetKeepList {
    <# Top-level `keep_list: ['*heretic*', ...]` glob list (models Kevin keeps for
       personal use — inventory tags them, recommendations never propose culling).
       Returns string[] (empty if the key or file is absent). #>
    param([string]$Path = $script:DefaultFleetPath)
    if (-not (Test-Path $Path)) { return @() }
    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^\s*keep_list:\s*\[(.*)\]\s*$') {
            $inner = $matches[1].Trim()
            if (-not $inner) { return @() }
            return @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
        }
    }
    return @()
}
```

- [ ] **Step 4: Run the suite.** `pwsh -NoProfile -File scripts/test-fleet-lib.ps1` — Expected: ALL checks PASS (pre-existing ones prove no regression; `research_default`/`general_capabilities` precede `providers:` in fixtures, so hardening must not break them).

- [ ] **Step 5: Run neighbors that consume Read-Fleet.** `pwsh -NoProfile -File scripts/test-fleet-dispatch.ps1` and `scripts/test-routing-lib.ps1` — Expected: PASS (the env-block parse and every existing field path unchanged).

- [ ] **Step 6: Commit.**

```bash
git add scripts/fleet-lib.ps1 scripts/test-fleet-lib.ps1
git commit -m "feat(fleet-lib): inline-list values + top-level-key hardening + keep_list reader"
```

---

### Task 2: routing-lib.ps1 — capability claims, context floors, champion mode

**Files:**
- Modify: `scripts/routing-lib.ps1` (`Select-Capability` ~83–144; new `Get-CapabilityFloors` after `Get-GeneralCapabilities` ~56)
- Test: `scripts/test-routing-lib.ps1`

- [ ] **Step 1: Write failing tests.** Append inside the try block of `scripts/test-routing-lib.ps1` (reuse `$tmp`, `$toolsPath`; ratings/journal isolation via `$nopath`-style non-existent files):

```powershell
    # ===== models-as-tools: claims, floors, champion mode =====
    $claimsYaml = @"
general_capabilities: [code-gen, reasoning, summarize]
capability_floors:
  summarize-long: 65536
  judge: 4096

providers:
  - name: frontier
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'claude -p "{{prompt}}"'
  - name: big-local
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    capabilities: [code-gen, summarize-long]
    context: 32768
  - name: small-local
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    capabilities: [judge, commit-msg, summarize-long]
    context: 131072
    quality: 0.4
"@
    $claimsFleet = Join-Path $tmp 'claims-fleet.yaml'
    Set-Content -Path $claimsFleet -Value $claimsYaml -Encoding utf8
    $noRatings = Join-Path $tmp 'no-ratings.jsonl'; $noJournal = Join-Path $tmp 'no-journal.jsonl'

    Check 'floors reader' ((Get-CapabilityFloors -FleetPath $claimsFleet)['summarize-long'] -eq 65536)
    Check 'floors absent -> empty' ((Get-CapabilityFloors -FleetPath (Join-Path $tmp 'no-such.yaml')).Count -eq 0)

    # Claims GRANT beyond the general list: judge is not a general capability.
    $cJudge = @(Select-Capability -Capability 'judge' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal)
    Check 'claim grants non-general cap' (@($cJudge | Where-Object { $_.name -eq 'small-local' }).Count -eq 1)
    # Claims RESTRICT: big-local declares a list without 'reasoning', so it is out;
    # field-less frontier keeps the blanket grant.
    $cReason = @(Select-Capability -Capability 'reasoning' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal)
    Check 'claim list restricts'   (@($cReason | Where-Object { $_.name -eq 'big-local' }).Count -eq 0)
    Check 'no-field keeps blanket' (@($cReason | Where-Object { $_.name -eq 'frontier' }).Count -eq 1)
    # Context floor: big-local claims summarize-long but 32768 < 65536 -> filtered;
    # small-local (131072) survives.
    $cLong = @(Select-Capability -Capability 'summarize-long' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal)
    Check 'floor filters short context' (@($cLong | Where-Object { $_.name -eq 'big-local' }).Count -eq 0)
    Check 'floor passes long context'   (@($cLong | Where-Object { $_.name -eq 'small-local' }).Count -eq 1)
    # Champion mode: quality desc beats cost-tier asc. code-gen candidates include
    # paid frontier (quality 0.5 prior) and big-local (0.5) + tools; with small-local
    # quality 0.4 on judge, economy puts local first regardless; use code-gen:
    $cEco = @(Select-Capability -Capability 'code-gen' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal)
    Check 'economy: local outranks paid' ($cEco[0].cost_tier -eq 'local')
    $cChamp = @(Select-Capability -Capability 'judge' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal -SelectionMode champion)
    # small-local is the only judge candidate; assert the mode is accepted + ranked.
    Check 'champion mode returns ranked' (@($cChamp).Count -eq 1 -and $cChamp[0].name -eq 'small-local')
```

Then a discriminating champion test — two providers claiming the same cap, the EXPENSIVE one higher quality:

```powershell
    $champYaml = @"
general_capabilities: []

providers:
  - name: cheap-ok
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://x'
    capabilities: [extract-json]
    quality: 0.55
  - name: paid-great
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'x "{{prompt}}"'
    capabilities: [extract-json]
    quality: 0.95
"@
    $champFleet = Join-Path $tmp 'champ-fleet.yaml'
    Set-Content -Path $champFleet -Value $champYaml -Encoding utf8
    $e = @(Select-Capability -Capability 'extract-json' -ToolsPath (Join-Path $tmp 'no-tools.yaml') -FleetPath $champFleet -RatingsPath $noRatings -JournalPath $noJournal)
    $h = @(Select-Capability -Capability 'extract-json' -ToolsPath (Join-Path $tmp 'no-tools.yaml') -FleetPath $champFleet -RatingsPath $noRatings -JournalPath $noJournal -SelectionMode champion)
    Check 'economy: cheapest first'  ($e[0].name -eq 'cheap-ok')
    Check 'champion: best first'     ($h[0].name -eq 'paid-great')
```

- [ ] **Step 2: Run to verify failures.** `pwsh -NoProfile -File scripts/test-routing-lib.ps1` — Expected: FAIL (`Get-CapabilityFloors` undefined; `-SelectionMode` not a parameter; judge claim yields no candidates).

- [ ] **Step 3: Implement.** In `scripts/routing-lib.ps1`:

(a) After `Get-GeneralCapabilities`, add:

```powershell
function Get-CapabilityFloors {
    <# Top-level `capability_floors:` block map (capability -> min context tokens).
       A claim is filtered when the provider's loaded context is KNOWN and below
       the floor; unknown context never disqualifies. Returns hashtable. #>
    param([string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'))
    $floors = @{}
    if (-not (Test-Path $FleetPath)) { return $floors }
    $inBlock = $false
    foreach ($line in (Get-Content $FleetPath)) {
        if ($line -match '^capability_floors:\s*$') { $inBlock = $true; continue }
        if (-not $inBlock) { continue }
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }
        if ($line -match '^\s+([\w.-]+):\s*(\d+)') { $floors[$matches[1]] = [int]$matches[2]; continue }
        $inBlock = $false   # dedented to the next top-level key — block over
    }
    return $floors
}
```

(b) In `Select-Capability`: add the parameter (after `$MaxCostTier`):

```powershell
        [ValidateSet('economy','champion')][string]$SelectionMode = 'economy',
```

(c) Replace step 2 (the `$general = ...` line through the end of its `if` block) with:

```powershell
    # 2. Fleet candidates — claims-aware. A provider WITH a `capabilities:` list is
    #    a candidate for exactly those (even non-general ones, e.g. judge); a provider
    #    WITHOUT the field keeps the blanket general_capabilities grant (frontier CLIs).
    #    Context floors filter claims whose loaded context is known-too-small.
    $general = Get-GeneralCapabilities -FleetPath $FleetPath
    $floors  = Get-CapabilityFloors -FleetPath $FleetPath
    if (Test-Path $FleetPath) {
        foreach ($p in (Read-Fleet -Path $FleetPath)) {
            if ($p.enabled -ne $true) { continue }
            $claims = $p.capabilities
            $isCandidate = if ($null -ne $claims) { @($claims) -contains $Capability }
                           else { $general -contains $Capability }
            if (-not $isCandidate) { continue }
            if ($floors.ContainsKey($Capability) -and $p.context) {
                if ([int]$p.context -lt $floors[$Capability]) { continue }
            }
            $prior = if ($null -ne $p.quality) { [double]$p.quality } else { 0.5 }
            $detail = Get-CapabilityQualityDetail -Capability $Capability -Candidate ([string]$p.name) -Prior $prior -JournalPath $JournalPath -RatingsPath $RatingsPath
            $why = if ($null -ne $claims) { "claims $Capability ($($p.cost_tier) tier)" }
                   else { "general model for $Capability ($($p.cost_tier) tier)" }
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$p.name; kind = [string]$p.kind; source = 'fleet'
                cost_tier = [string]$p.cost_tier; quality = $detail.quality
                quality_detail = $detail
                role = $p.role; platform = $p.platform
                why = $why
            })
        }
    }
```

(d) Replace step 4 (the `$ranked = ...` pipeline) with:

```powershell
    # 4. Rank. economy: cost tier asc, quality desc ("smallest that clears the bar").
    #    champion: quality desc, cost tier asc tiebreak ("just the best" — BoB slot).
    if ($SelectionMode -eq 'champion') {
        $ranked = $filtered |
            Select-Object *, @{n='score'; e={ -$_.quality + ((Get-CostTierRank $_.cost_tier) * 0.001) }} |
            Sort-Object @{e={ -$_.quality }}, @{e={ Get-CostTierRank $_.cost_tier }}, @{e='name'}
    } else {
        $ranked = $filtered |
            Select-Object *, @{n='score'; e={ (Get-CostTierRank $_.cost_tier) - ($_.quality * 0.001) }} |
            Sort-Object @{e='score'}, @{e={ -$_.quality }}, @{e='name'}
    }
    return ,([object[]]$ranked)
```

- [ ] **Step 4: Run.** `pwsh -NoProfile -File scripts/test-routing-lib.ps1` — Expected: ALL PASS (pre-existing general-capability tests prove the field-less path is unchanged).

- [ ] **Step 5: Run consumers.** `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`, `scripts/test-routing-cascade.ps1` — Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add scripts/routing-lib.ps1 scripts/test-routing-lib.ps1
git commit -m "feat(routing): capability claims + context floors + economy/champion selection"
```

---

### Task 3: routing-learn.ps1 — Get-JudgeModel, grader wiring

**Files:**
- Modify: `scripts/routing-learn.ps1` (new function after `Get-CheapestLocalModel` ~154; one line in `Get-LlmJudgeGrader` ~208)
- Test: `scripts/test-routing-learn.ps1`

- [ ] **Step 1: Write failing tests.** Append inside the try block (the suite dot-sources `routing-lib.ps1`, so `Select-Capability` IS loaded):

```powershell
    # ===== models-as-tools: judge resolved by claim, not file order =====
    $judgeYaml = @"
general_capabilities: [code-gen]

providers:
  - name: first-local-drafter
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://x'
  - name: claimed-judge
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://x'
    capabilities: [judge]
"@
    $judgeFleet = Join-Path $tmp 'judge-fleet.yaml'
    Set-Content -Path $judgeFleet -Value $judgeYaml -Encoding utf8
    $jmNoR = Join-Path $tmp 'jm-no-ratings.jsonl'; $jmNoJ = Join-Path $tmp 'jm-no-journal.jsonl'
    Check 'judge: claim beats file order' ((Get-JudgeModel -FleetPath $judgeFleet -ToolsPath (Join-Path $tmp 'no-tools.yaml') -RatingsPath $jmNoR -JournalPath $jmNoJ) -eq 'claimed-judge')

    $bareYaml = @"
general_capabilities: [code-gen]

providers:
  - name: only-local
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://x'
"@
    $bareFleet = Join-Path $tmp 'bare-fleet.yaml'
    Set-Content -Path $bareFleet -Value $bareYaml -Encoding utf8
    Check 'judge: no claim -> first-local fallback' ((Get-JudgeModel -FleetPath $bareFleet -ToolsPath (Join-Path $tmp 'no-tools.yaml') -RatingsPath $jmNoR -JournalPath $jmNoJ) -eq 'only-local')
    Check 'judge: no locals -> null' ($null -eq (Get-JudgeModel -FleetPath (Join-Path $tmp 'no-such.yaml') -ToolsPath (Join-Path $tmp 'no-tools.yaml') -RatingsPath $jmNoR -JournalPath $jmNoJ))
```

- [ ] **Step 2: Run to verify failure.** `pwsh -NoProfile -File scripts/test-routing-learn.ps1` — Expected: FAIL with `Get-JudgeModel` not recognized.

- [ ] **Step 3: Implement.** In `scripts/routing-learn.ps1` after `Get-CheapestLocalModel`:

```powershell
function Get-JudgeModel {
    <# Resolve the judge via capability claims: best enabled LOCAL provider claiming
       'judge' (Select-Capability ranking). Falls back to the first enabled local
       (Get-CheapestLocalModel) when nobody claims judge, or when this lib is loaded
       standalone without routing-lib (Select-Capability absent). Replaces the
       file-order pick that dialed an offline box on 2026-06-11. #>
    param(
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl')
    )
    if (Get-Command Select-Capability -ErrorAction SilentlyContinue) {
        $c = @(Select-Capability -Capability 'judge' -RequireLocal -FleetPath $FleetPath -ToolsPath $ToolsPath -RatingsPath $RatingsPath -JournalPath $JournalPath)
        if ($c.Count -gt 0) { return [string]$c[0].name }
    }
    return Get-CheapestLocalModel -FleetPath $FleetPath
}
```

In `Get-LlmJudgeGrader`, change the model line to:

```powershell
        $model = if ($jm) { $jm } else { Get-JudgeModel -FleetPath $fp }
```

- [ ] **Step 4: Run.** `pwsh -NoProfile -File scripts/test-routing-learn.ps1` — Expected: ALL PASS. The existing grader tests pass `-JudgeModel`/no-fleet paths, so the fallback chain (`judge unavailable: no local model` → heuristic) is already asserted and must stay green.

- [ ] **Step 5: Commit.**

```bash
git add scripts/routing-learn.ps1 scripts/test-routing-learn.ps1
git commit -m "feat(routing): Get-JudgeModel — judge resolved by capability claim with first-local fallback"
```

---

### Task 4: routing-learn.ps1 — scorecard import + gauntlet evidence bucket

**Files:**
- Modify: `scripts/routing-learn.ps1` (`Get-RoutingStats` ~69–97, `Get-CapabilityQualityDetail` ~99–122; new `Import-GauntletScorecard` after `Add-CapabilityRating`)
- Test: `scripts/test-routing-learn.ps1`

- [ ] **Step 1: Write failing tests.** Append inside the try block:

```powershell
    # ===== models-as-tools: Gauntlet scorecard import =====
    $scorecard = @{
        run = @{ id = 'run-001'; date = '2026-06-11T00:00:00Z'; gauntlet_version = '0.1' }
        cells = @(
            @{ model = 'phi-4'; capability = 'extract-json'; quality = 0.91; cases = 14 },
            @{ model = 'phi-4'; capability = 'judge'; quality = 0.85; cases = 20 },
            @{ model = 'unknown-model'; capability = 'ocr'; quality = 0.7; cases = 5 },
            @{ capability = 'broken-cell-no-model'; quality = 0.5 }
        )
    } | ConvertTo-Json -Depth 5
    $scPath = Join-Path $tmp 'scorecard.json'
    Set-Content -Path $scPath -Value $scorecard -Encoding utf8
    $scFleetYaml = @"
providers:
  - name: lm-studio-small
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://x'
    model_default: 'phi-4'
"@
    $scFleet = Join-Path $tmp 'sc-fleet.yaml'
    Set-Content -Path $scFleet -Value $scFleetYaml -Encoding utf8
    $scRatings = Join-Path $tmp 'sc-ratings.jsonl'

    $imp = Import-GauntletScorecard -Path $scPath -RatingsPath $scRatings -FleetPath $scFleet
    Check 'import: cell count'      ($imp.imported -eq 3 -and $imp.skipped -eq 1 -and $imp.already -eq $false)
    Check 'import: unmapped counted' ($imp.unmapped -eq 1)
    $scRows = @(Read-JsonlRows -Path $scRatings)
    Check 'import: pin maps to provider' (@($scRows | Where-Object { $_.candidate -eq 'lm-studio-small' }).Count -eq 2)
    Check 'import: unmapped keeps raw id' (@($scRows | Where-Object { $_.candidate -eq 'unknown-model' }).Count -eq 1)
    Check 'import: source tagged'   (@($scRows | Where-Object { $_.source -eq 'gauntlet' }).Count -eq 3)
    $imp2 = Import-GauntletScorecard -Path $scPath -RatingsPath $scRatings -FleetPath $scFleet
    Check 'import: idempotent by run id' ($imp2.already -eq $true -and $imp2.imported -eq 0 -and @(Read-JsonlRows -Path $scRatings).Count -eq 3)

    # Quality blend: gauntlet evidence moves quality off the prior; user bucket unpolluted.
    $qd = Get-CapabilityQualityDetail -Capability 'extract-json' -Candidate 'lm-studio-small' -RatingsPath $scRatings -JournalPath (Join-Path $tmp 'sc-no-journal.jsonl')
    Check 'blend: gauntlet bucket present' ($qd.gauntlet.n -eq 10)   # min(14 cases, 10)
    Check 'blend: quality pulled toward 0.91' ($qd.quality -gt 0.7)
    Check 'blend: user bucket unpolluted' ($qd.user.n -eq 0)

    # Malformed scorecards: named errors.
    Set-Content -Path (Join-Path $tmp 'bad-sc.json') -Value '{"cells": []}' -Encoding utf8
    $threw = $false
    try { Import-GauntletScorecard -Path (Join-Path $tmp 'bad-sc.json') -RatingsPath $scRatings -FleetPath $scFleet | Out-Null } catch { $threw = $_.Exception.Message -match 'run.id' }
    Check 'import: missing run.id throws named' $threw
```

- [ ] **Step 2: Run to verify failure.** Expected: FAIL with `Import-GauntletScorecard` not recognized.

- [ ] **Step 3: Implement.** In `scripts/routing-learn.ps1`:

(a) After `Add-CapabilityRating`, add:

```powershell
function Import-GauntletScorecard {
    <# Import a Gauntlet scorecard (the spec'd contract: run{id,date}, cells[]) into
       the ratings store as source='gauntlet' rows. Idempotent by run id. A cell whose
       model id matches a provider's model_default is recorded under the PROVIDER name
       (the routing candidate); unmapped cells keep the raw model id (future pins make
       them retroactively useful). Cells missing model/capability/quality are skipped
       and counted. Returns @{imported; skipped; unmapped; already; run_id}. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
    )
    if (-not (Test-Path $Path)) { throw "scorecard not found: $Path" }
    $sc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $sc.run -or -not $sc.run.id) { throw "scorecard missing run.id: $Path" }
    if ($null -eq $sc.cells) { throw "scorecard missing cells[]: $Path" }
    $runId = [string]$sc.run.id
    if (@(Read-JsonlRows -Path $RatingsPath | Where-Object { $_.run_id -eq $runId }).Count -gt 0) {
        return @{ imported = 0; skipped = 0; unmapped = 0; already = $true; run_id = $runId }
    }
    $pinMap = @{}
    if (Test-Path $FleetPath) {
        foreach ($p in (Read-Fleet -Path $FleetPath)) {
            if ($p.model_default) { $pinMap[[string]$p.model_default] = [string]$p.name }
        }
    }
    $imported = 0; $skipped = 0; $unmapped = 0
    $ts = if ($sc.run.date) { [string]$sc.run.date } else { (Get-Date).ToString('o') }
    $dir = Split-Path -Parent $RatingsPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    foreach ($cell in @($sc.cells)) {
        if (-not $cell.model -or -not $cell.capability -or $null -eq $cell.quality) { $skipped++; continue }
        $candidate = if ($pinMap.ContainsKey([string]$cell.model)) { $pinMap[[string]$cell.model] }
                     else { $unmapped++; [string]$cell.model }
        $row = [ordered]@{
            ts = $ts; capability = [string]$cell.capability; candidate = $candidate
            source = 'gauntlet'; score = [double]$cell.quality
            n_cases = $(if ($cell.cases) { [int]$cell.cases } else { 1 })
            run_id = $runId
        }
        Add-Content -LiteralPath $RatingsPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8NoBOM
        $imported++
    }
    return @{ imported = $imported; skipped = $skipped; unmapped = $unmapped; already = $false; run_id = $runId }
}
```

(b) In `Get-RoutingStats`, replace the user-ratings block and extend the return:

```powershell
    # User ratings (exclude scorecard rows — they carry score, not good/bad; without
    # this filter gauntlet rows would silently DRAG DOWN the user rate).
    $rtAll = Get-CapabilityRatings -Capability $Capability -Candidate $Candidate -RatingsPath $RatingsPath
    $rt = @($rtAll | Where-Object { $_.rating -eq 'good' -or $_.rating -eq 'bad' })
    $nu = @($rt).Count
    $gu = @($rt | Where-Object { $_.rating -eq 'good' }).Count
    $ru = if ($nu -gt 0) { [double]$gu / $nu } else { 0.0 }

    # Gauntlet scorecard cells: calibration-grade evidence. Each cell contributes its
    # case count capped at 10 (one bench run must not drown live signals forever).
    $gc = @($rtAll | Where-Object { $_.source -eq 'gauntlet' -and $null -ne $_.score })
    $ng = 0; $gsum = 0.0
    foreach ($g in $gc) {
        $w = [Math]::Min([int]$(if ($g.n_cases) { $g.n_cases } else { 1 }), 10)
        $ng += $w; $gsum += $w * [double]$g.score
    }
    $rg = if ($ng -gt 0) { $gsum / $ng } else { 0.0 }
```

and add to the returned hashtable:

```powershell
        gauntlet  = @{ rate = $rg; n = [int]$ng }
```

(c) In `Get-CapabilityQualityDetail`, weight the new bucket between user (1.0) and judge (0.5) — a calibrated bench beats one judge verdict, not an explicit human rating:

```powershell
    $k  = 2.0; $Wu = 1.0; $Wg = 0.75; $Wj = 0.5; $Wh = 0.25
    $numer = ($Prior * $k) + ($Wu * $s.user.n * $s.user.rate) + ($Wg * $s.gauntlet.n * $s.gauntlet.rate) + ($Wj * $s.judge.n * $s.judge.rate) + ($Wh * $s.heuristic.n * $s.heuristic.rate)
    $denom = $k + ($Wu * $s.user.n) + ($Wg * $s.gauntlet.n) + ($Wj * $s.judge.n) + ($Wh * $s.heuristic.n)
```

and add `gauntlet = $s.gauntlet` to the returned detail hashtable.

- [ ] **Step 4: Run.** `pwsh -NoProfile -File scripts/test-routing-learn.ps1` — Expected: ALL PASS (existing blend tests use good/bad rows and journal rows only; with `$s.gauntlet.n -eq 0` the new term is zero and their numbers are unchanged).

- [ ] **Step 5: Run blend consumers.** `pwsh -NoProfile -File scripts/test-routing-lib.ps1`, `scripts/test-routing-calibrate.ps1` — Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add scripts/routing-learn.ps1 scripts/test-routing-learn.ps1
git commit -m "feat(routing): Import-GauntletScorecard + gauntlet evidence bucket in the quality blend"
```

---

### Task 5: fleet-models.ps1 — inventory engine + command + suite

**Files:**
- Create: `scripts/fleet-models.ps1`
- Create: `scripts/test-fleet-models.ps1`
- Create: `commands/models.md`

- [ ] **Step 1: Write the failing test suite.** Create `scripts/test-fleet-models.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-models.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fm-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # --- Fixtures: registry with two providers on one LM Studio box + one ollama box ---
    $fleetYaml = @"
keep_list: ['*heretic*']

providers:
  - name: lm-studio
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    model_default: 'qwen/qwen3-coder-30b'
    capabilities: [code-gen]
    usage_class: broad
  - name: lm-studio-small
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    model_default: 'phi-4'
    capabilities: [judge, extract-json]
    usage_class: tight
  - name: ollama-box2
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://100.115.71.9:11434'
    model_default: 'dolphin3:8b'
  - name: claude-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'claude -p "{{prompt}}"'
"@
    $fleetPath = Join-Path $tmp 'fleet.yaml'
    Set-Content -Path $fleetPath -Value $fleetYaml -Encoding utf8

    $lmJson = @'
{"data":[
  {"id":"qwen/qwen3-coder-30b","type":"llm","arch":"qwen3","quantization":"Q4_K_M","state":"loaded","max_context_length":262144,"capabilities":["tool_use"]},
  {"id":"phi-4","type":"llm","arch":"phi","quantization":"Q4_K_M","state":"not-loaded","max_context_length":16384,"capabilities":["structured_output","reasoning"]},
  {"id":"gemma-heretic-9b","type":"llm","arch":"gemma","quantization":"Q4_K_M","state":"not-loaded","max_context_length":8192,"capabilities":[]},
  {"id":"qwen3-embedding-8b","type":"embedding","arch":"qwen3","quantization":"Q8_0","state":"not-loaded","max_context_length":32768,"capabilities":[]},
  {"id":"llama-twin-a-7b","type":"llm","arch":"llama","quantization":"Q4_K_M","state":"not-loaded","max_context_length":8192,"capabilities":[],"size_bytes":4200000000},
  {"id":"llama-twin-b-7b","type":"llm","arch":"llama","quantization":"Q5_K_M","state":"not-loaded","max_context_length":8192,"capabilities":[],"size_bytes":4500000000}
]}
'@
    $olJson = @'
{"models":[
  {"name":"dolphin3:8b","size":4900000000,"details":{"family":"llama","quantization_level":"Q4_K_M","parameter_size":"8.0B"}}
]}
'@

    # --- Normalizers ---
    $lmRows = @(ConvertFrom-LmStudioModels -RawJson $lmJson)
    Check 'lm: row count'        ($lmRows.Count -eq 6)
    Check 'lm: fields mapped'    ($lmRows[0].id -eq 'qwen/qwen3-coder-30b' -and $lmRows[0].max_context -eq 262144 -and $lmRows[0].loaded -eq $true)
    Check 'lm: reasoning flag'   ($lmRows[1].flags -contains 'reasoning')
    Check 'lm: embedding type'   ($lmRows[3].type -eq 'embedding')
    $olRows = @(ConvertFrom-OllamaTags -RawJson $olJson)
    Check 'ol: fields mapped'    ($olRows[0].id -eq 'dolphin3:8b' -and $olRows[0].size_bytes -eq 4900000000 -and $olRows[0].family -eq 'llama')

    # --- Inventory: dedupe by base_url, prober injected, offline box survives ---
    $script:probed = [System.Collections.ArrayList]@()
    $prober = {
        param($url)
        [void]$script:probed.Add($url)
        if ($url -like 'http://localhost:1234*') { return $lmJson }
        throw "connection refused"
    }.GetNewClosure()
    $inv = Get-ModelInventory -FleetPath $fleetPath -Prober $prober
    Check 'inv: one probe per box'      (@($script:probed).Count -eq 2)
    Check 'inv: lm box reachable'       (@($inv.boxes | Where-Object { $_.base_url -eq 'http://localhost:1234' })[0].reachable -eq $true)
    Check 'inv: providers grouped'      (@(@($inv.boxes | Where-Object { $_.base_url -eq 'http://localhost:1234' })[0].providers).Count -eq 2)
    Check 'inv: offline box marked'     (@($inv.boxes | Where-Object { $_.base_url -like '*11434*' })[0].reachable -eq $false)
    Check 'inv: cli providers ignored'  (@($inv.boxes | Where-Object { $_.providers -contains 'claude-cli' }).Count -eq 0)

    # --- Tags ---
    $inv = Add-InventoryTags -Inventory $inv -FleetPath $fleetPath
    $lmBox = @($inv.boxes | Where-Object { $_.base_url -eq 'http://localhost:1234' })[0]
    $phi = @($lmBox.models | Where-Object { $_.id -eq 'phi-4' })[0]
    Check 'tag: pinned_by'       ($phi.pinned_by -contains 'lm-studio-small')
    Check 'tag: claims'          ($phi.claims -contains 'judge')
    Check 'tag: keep glob'       (@($lmBox.models | Where-Object { $_.id -eq 'gemma-heretic-9b' })[0].keep -eq $true)
    Check 'tag: unregistered'    (@($lmBox.models | Where-Object { $_.id -eq 'qwen3-embedding-8b' })[0].unregistered -eq $true)

    # --- Recommendations ---
    $recs = @(Get-InventoryRecommendations -Inventory $inv -FleetPath $fleetPath)
    Check 'rec: judge risk (reasoning flag)'  (@($recs | Where-Object { $_ -match 'JUDGE RISK.*phi-4' }).Count -eq 1)
    Check 'rec: near-dup pair'                (@($recs | Where-Object { $_ -match 'NEAR-DUP.*llama-twin' }).Count -eq 1)
    Check 'rec: unregistered specialist'      (@($recs | Where-Object { $_ -match 'UNREGISTERED SPECIALIST.*qwen3-embedding-8b' }).Count -eq 1)
    Check 'rec: offline box noted'            (@($recs | Where-Object { $_ -match 'offline.*ollama-box2' }).Count -eq 1)
    Check 'rec: keep never culled'            (@($recs | Where-Object { $_ -match 'heretic' }).Count -eq 0)

    # --- Missing pin: registry pins a model the box doesn't have ---
    $fleet2 = $fleetYaml.Replace("model_default: 'phi-4'", "model_default: 'phi-9-imaginary'")
    $fleet2Path = Join-Path $tmp 'fleet2.yaml'
    Set-Content -Path $fleet2Path -Value $fleet2 -Encoding utf8
    $inv2 = Add-InventoryTags -Inventory (Get-ModelInventory -FleetPath $fleet2Path -Prober $prober) -FleetPath $fleet2Path
    $recs2 = @(Get-InventoryRecommendations -Inventory $inv2 -FleetPath $fleet2Path)
    Check 'rec: missing pin'     (@($recs2 | Where-Object { $_ -match 'MISSING PIN.*phi-9-imaginary' }).Count -eq 1)
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILURES" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASS" -ForegroundColor Green; exit 0
```

- [ ] **Step 2: Run to verify failure.** `pwsh -NoProfile -File scripts/test-fleet-models.ps1` — Expected: FAIL (fleet-models.ps1 missing).

- [ ] **Step 3: Implement `scripts/fleet-models.ps1`.**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Model inventory for /baton:models. Probes each enabled local http provider's box
  (LM Studio native /api/v1/models; ollama /api/tags), joins with registry pins,
  claims, and the keep_list, writes a snapshot, prints a table + recommendations.
  Recommend-only: never installs or deletes a model.

.NOTES
  Dot-source for the function library (tests do); run as a script for the command.
  -Import hands off to Import-GauntletScorecard (routing-learn.ps1).
#>
param(
    [switch]$Json,
    [string]$Box,
    [string]$Import,
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$SnapshotPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'model-inventory.json' } else { Join-Path $HOME '.baton/model-inventory.json' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

function ConvertFrom-LmStudioModels {
    <# Normalize LM Studio native GET /api/v1/models JSON to inventory rows.
       Tolerant: absent fields -> $null/empty, never throws on shape drift. #>
    param([Parameter(Mandatory)][string]$RawJson)
    $o = $RawJson | ConvertFrom-Json -ErrorAction Stop
    return @(foreach ($m in @($o.data)) {
        [pscustomobject]@{
            id          = [string]$m.id
            type        = $(if ($m.type) { [string]$m.type } else { 'llm' })
            quant       = [string]$m.quantization
            max_context = $(if ($m.max_context_length) { [int]$m.max_context_length } else { $null })
            size_bytes  = $(if ($m.size_bytes) { [long]$m.size_bytes } else { $null })
            flags       = @(@($m.capabilities) | ForEach-Object { [string]$_ })
            loaded      = ($m.state -eq 'loaded')
            family      = [string]$m.arch
        }
    })
}

function ConvertFrom-OllamaTags {
    <# Normalize ollama GET /api/tags JSON to the same row shape (less metadata). #>
    param([Parameter(Mandatory)][string]$RawJson)
    $o = $RawJson | ConvertFrom-Json -ErrorAction Stop
    return @(foreach ($m in @($o.models)) {
        [pscustomobject]@{
            id          = [string]$m.name
            type        = 'llm'
            quant       = [string]$m.details.quantization_level
            max_context = $null
            size_bytes  = $(if ($m.size) { [long]$m.size } else { $null })
            flags       = @()
            loaded      = $null
            family      = [string]$m.details.family
        }
    })
}

function Get-ModelInventory {
    <# Probe each enabled local http provider's box, deduped by base_url (lm-studio +
       lm-studio-small share one server — ONE probe). Enrichment kind by provider name
       prefix: ollama* -> /api/tags, anything else -> LM Studio native /api/v1/models.
       -Prober (param: url -> raw json string) injectable; default = HTTP GET 10s.
       Unreachable boxes are marked, never fatal (wraith2 is often off). #>
    param(
        [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
        [scriptblock]$Prober
    )
    if (-not $Prober) {
        $Prober = { param($url) (Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing).Content }
    }
    $locals = @(Read-Fleet -Path $FleetPath | Where-Object {
        $_.enabled -eq $true -and $_.cost_tier -eq 'local' -and $_.kind -eq 'http' -and $_.base_url
    })
    $byUrl = [ordered]@{}
    foreach ($p in $locals) {
        if (-not $byUrl.Contains([string]$p.base_url)) { $byUrl[[string]$p.base_url] = [System.Collections.ArrayList]@() }
        [void]$byUrl[[string]$p.base_url].Add($p)
    }
    $boxes = @(foreach ($url in $byUrl.Keys) {
        $provs = $byUrl[$url]
        $enrich = if ([string]$provs[0].name -like 'ollama*') { 'ollama' } else { 'lmstudio' }
        $probeUrl = if ($enrich -eq 'ollama') { "$url/api/tags" } else { "$url/api/v1/models" }
        $models = @(); $reachable = $true; $err = $null
        try {
            $raw = [string](& $Prober $probeUrl)
            $models = if ($enrich -eq 'ollama') { @(ConvertFrom-OllamaTags -RawJson $raw) } else { @(ConvertFrom-LmStudioModels -RawJson $raw) }
        } catch {
            $reachable = $false; $err = $_.Exception.Message
        }
        [pscustomobject]@{
            base_url = [string]$url; enrich = $enrich
            providers = @($provs | ForEach-Object { [string]$_.name })
            reachable = $reachable; error = $err; models = $models
        }
    })
    return [pscustomobject]@{ generated_at = (Get-Date).ToString('o'); boxes = $boxes }
}

function Add-InventoryTags {
    <# Join inventory rows with the registry: pinned_by (providers whose model_default
       is this model), claims (those providers' capabilities), keep (keep_list glob),
       unregistered (no pin). Returns the mutated inventory. #>
    param(
        [Parameter(Mandatory)]$Inventory,
        [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
    )
    $fleet = @(Read-Fleet -Path $FleetPath)
    $keep = @(Get-FleetKeepList -Path $FleetPath)
    foreach ($boxEntry in @($Inventory.boxes)) {
        $boxProviders = @($fleet | Where-Object { $boxEntry.providers -contains $_.name })
        foreach ($m in @($boxEntry.models)) {
            $pinned = @($boxProviders | Where-Object { [string]$_.model_default -eq $m.id })
            $claims = @($pinned | Where-Object { $_.capabilities } | ForEach-Object { @($_.capabilities) })
            $m | Add-Member -NotePropertyName pinned_by    -NotePropertyValue @($pinned | ForEach-Object { [string]$_.name }) -Force
            $m | Add-Member -NotePropertyName claims       -NotePropertyValue @($claims | Select-Object -Unique) -Force
            $m | Add-Member -NotePropertyName keep         -NotePropertyValue ([bool](@($keep | Where-Object { $m.id -like $_ }).Count)) -Force
            $m | Add-Member -NotePropertyName unregistered -NotePropertyValue ($pinned.Count -eq 0) -Force
        }
    }
    return $Inventory
}

function Get-InventoryRecommendations {
    <# Recommend-only heuristics over a tagged inventory. Returns string[]:
       MISSING PIN / JUDGE RISK / NEAR-DUP / UNREGISTERED SPECIALIST / offline notes.
       keep-tagged models are exempt from culling-flavored lines (hard exemption). #>
    param(
        [Parameter(Mandatory)]$Inventory,
        [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
    )
    $recs = [System.Collections.ArrayList]@()
    $fleet = @(Read-Fleet -Path $FleetPath)
    foreach ($boxEntry in @($Inventory.boxes)) {
        if (-not $boxEntry.reachable) {
            [void]$recs.Add("box $($boxEntry.base_url) offline — inventory stale for: $($boxEntry.providers -join ', ')")
            continue
        }
        $ids = @($boxEntry.models | ForEach-Object { $_.id })
        foreach ($p in @($fleet | Where-Object { $boxEntry.providers -contains $_.name -and $_.model_default })) {
            if ($ids -notcontains [string]$p.model_default) {
                [void]$recs.Add("MISSING PIN: provider '$($p.name)' pins '$($p.model_default)' but it is not installed on $($boxEntry.base_url)")
            }
        }
        foreach ($m in @($boxEntry.models)) {
            if ($m.flags -contains 'reasoning' -and $m.claims -contains 'judge') {
                [void]$recs.Add("JUDGE RISK: '$($m.id)' claims judge but is reasoning-flagged (thinking preamble breaks strict-JSON parsing)")
            }
        }
        $dupPool = @($boxEntry.models | Where-Object { $_.size_bytes -and $_.family -and -not $_.keep -and @($_.pinned_by).Count -eq 0 })
        for ($i = 0; $i -lt $dupPool.Count; $i++) {
            for ($j = $i + 1; $j -lt $dupPool.Count; $j++) {
                $a = $dupPool[$i]; $b = $dupPool[$j]
                if ($a.family -ne $b.family) { continue }
                $hi = [Math]::Max([long]$a.size_bytes, [long]$b.size_bytes)
                $lo = [Math]::Min([long]$a.size_bytes, [long]$b.size_bytes)
                if ($hi -gt 0 -and (($hi - $lo) / [double]$hi) -le 0.15) {
                    [void]$recs.Add("NEAR-DUP: '$($a.id)' and '$($b.id)' (family '$($a.family)', sizes within 15%) — consider keeping one")
                }
            }
        }
        foreach ($m in @($boxEntry.models | Where-Object { $_.unregistered -and -not $_.keep -and ($_.type -in @('embedding','vlm')) })) {
            [void]$recs.Add("UNREGISTERED SPECIALIST: '$($m.id)' ($($m.type)) installed but no provider pins it")
        }
    }
    return @($recs)
}

# ─── script entry (skipped when dot-sourced by tests) ───
if ($MyInvocation.InvocationName -eq '.') { return }

if ($Import) {
    . (Join-Path $PSScriptRoot 'routing-lib.ps1')   # loads routing-learn (Import-GauntletScorecard)
    $r = Import-GauntletScorecard -Path $Import -FleetPath $FleetPath
    if ($r.already) { Write-Host "scorecard run '$($r.run_id)' already imported — nothing to do" }
    else { Write-Host "imported $($r.imported) cells (skipped $($r.skipped), unmapped $($r.unmapped)) from run '$($r.run_id)'" }
    exit 0
}

$inv = Get-ModelInventory -FleetPath $FleetPath
$inv = Add-InventoryTags -Inventory $inv -FleetPath $FleetPath
if ($Box) { $inv = [pscustomobject]@{ generated_at = $inv.generated_at; boxes = @($inv.boxes | Where-Object { $_.providers -contains $Box }) } }
$snapshot = $inv | ConvertTo-Json -Depth 8
Set-JsonFileAtomic -Path $SnapshotPath -Json $snapshot
if ($Json) { Write-Output $snapshot; exit 0 }

foreach ($boxEntry in @($inv.boxes)) {
    Write-Host "`n== $($boxEntry.base_url) [$($boxEntry.enrich)] providers: $($boxEntry.providers -join ', ') ==" -ForegroundColor Cyan
    if (-not $boxEntry.reachable) { Write-Host "  OFFLINE: $($boxEntry.error)" -ForegroundColor Yellow; continue }
    $boxEntry.models | Sort-Object { -([long]($_.size_bytes ?? 0)) } |
        Format-Table @{n='model';e={$_.id}}, @{n='type';e={$_.type}}, @{n='quant';e={$_.quant}},
                     @{n='ctx';e={$_.max_context}}, @{n='loaded';e={$_.loaded}},
                     @{n='pins';e={$_.pinned_by -join ','}}, @{n='claims';e={$_.claims -join ','}},
                     @{n='keep';e={$_.keep}} -AutoSize | Out-Host
}
$recs = @(Get-InventoryRecommendations -Inventory $inv -FleetPath $FleetPath)
Write-Host "`n-- recommendations ($($recs.Count)) --" -ForegroundColor Cyan
foreach ($r in $recs) { Write-Host "  * $r" }
Write-Host "`nsnapshot: $SnapshotPath"
```

- [ ] **Step 4: Run.** `pwsh -NoProfile -File scripts/test-fleet-models.ps1` — Expected: ALL PASS.

- [ ] **Step 5: Create `commands/models.md`** (mirrors `commands/fleet.md` structure):

```markdown
---
description: Inventory the local model fleet. Probes each box's API (LM Studio native, ollama), joins with registry pins/claims/keep-list, prints recommendations. `--import` loads a Gauntlet scorecard into the ratings store.
argument-hint: "[--json] [--box <provider>] [--import <scorecard.json>]"
---

# /baton:models

Inventory the models installed on each registered local box, compare against
`$BATON_HOME/fleet.yaml` (pins, capability claims, keep_list), and surface
recommend-only findings (missing pins, judge risks, near-duplicates,
unregistered specialists). Never installs or deletes anything.

## Steps

1. **Parse `$ARGUMENTS`.** Recognize `--json`, `--box <provider-name>`, and
   `--import <path>`. Anything else: print usage and stop.

2. **Dispatch** (substitute parsed values):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-models.ps1" <ARGS>
   ```

   - default: echo the per-box tables and the recommendations section verbatim.
   - `--json`: emit the snapshot JSON (also always written to
     `$BATON_HOME/model-inventory.json`).
   - `--import <path>`: forwards to `Import-GauntletScorecard`; report the
     imported/skipped/unmapped counts it prints.

3. **Summarize for the user** in 2-4 plain-language bullets: how many models
   per box, anything OFFLINE, and each recommendation line with a one-clause
   explanation. Do not act on recommendations — Kevin decides.
```

- [ ] **Step 6: Commit.**

```bash
git add scripts/fleet-models.ps1 scripts/test-fleet-models.ps1 commands/models.md
git commit -m "feat(models): /baton:models inventory engine — probes, tags, recommendations, scorecard import surface"
```

---

### Task 6: seed YAML, fleet doctor, bootstrap, version

**Files:**
- Modify: `references/fleet.yaml`
- Modify: `scripts/fleet-doctor.ps1`
- Modify: `scripts/bootstrap.ps1` (~line 259 lib manifest)
- Modify: `scripts/test-bootstrap.ps1`
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Seed registry.** In `references/fleet.yaml`: read the file first. (a) Extend the header comment doc with the new fields:

```yaml
#   capabilities      (optional) explicit capability claims — a provider WITH this
#                     list is a candidate for ONLY those capabilities; without it,
#                     the blanket general_capabilities grant applies (frontier CLIs).
#                     Canonical taxonomy (matches Gauntlet battery names):
#                     code-gen, code-transform, commit-msg, extract-json,
#                     summarize-short, summarize-long, synthesize, write-personal,
#                     write-scientific, write-formal, ocr, embed, judge, reasoning, vision
#   context           (optional) loaded context of the pinned profile (tokens);
#                     claims below a capability_floors entry are filtered out
#   usage_class       (optional) tight (small specialist, fine while Kevin is active)
#                     | broad (15GB+ generalist, idle-gated in a later slice)
```

(b) Insert immediately ABOVE the `providers:` line (top-level blocks must precede or follow `providers:` as standalone keys — the parser closes the provider list at any new top-level key):

```yaml
# Min context (tokens) a provider must declare to claim a capability.
capability_floors:
  summarize-long: 65536
  judge: 4096

# Personal/keep models (globs): inventory tags them, recommendations never
# propose culling them, the router can never claim them (they're unregistered).
keep_list: ['*heretic*']
```

(c) On the seed's local http entries add example claims (adjust to the entries present in the file — lm-studio gets `capabilities: [code-gen, code-transform, summarize-short, synthesize]`, `context: 32768`, `usage_class: broad`; lm-studio-small gets `capabilities: [judge, commit-msg, extract-json, summarize-short]`, `context: 16384`, `usage_class: tight`; the box2/ollama entry gets `usage_class: tight`).

- [ ] **Step 2: Fleet doctor surfaces usage_class.** In `scripts/fleet-doctor.ps1`, find where the per-provider row objects are built (read the file; rows feed both the table and `-Json`) and add a `class` property: `class = $(if ($p.usage_class) { [string]$p.usage_class } else { '' })`, including it in the table output. Add one assert to `scripts/test-fleet-doctor.ps1`: a fixture provider with `usage_class: tight` shows `tight` in the doctor's `-Json` output (the suite already runs doctor against fixture YAML — follow its existing pattern).

- [ ] **Step 3: Bootstrap deploys fleet-models.ps1.** In `scripts/bootstrap.ps1` line ~259, add `'fleet-models.ps1'` to the lib-script array (after `'run-backlog.ps1'`). In `scripts/test-bootstrap.ps1`, find the existing deployed-scripts assertions (they check fleet-backlog.ps1 etc. — added in Slice C) and add the same assert for `fleet-models.ps1`.

- [ ] **Step 4: Version bump.** `.claude-plugin/plugin.json`: `"version": "1.2.0-rc.6"` → `"1.2.0-rc.7"`.

- [ ] **Step 5: Run.** `pwsh -NoProfile -File scripts/test-bootstrap.ps1` and `scripts/test-fleet-doctor.ps1` — Expected: ALL PASS.

- [ ] **Step 6: Commit.**

```bash
git add references/fleet.yaml scripts/fleet-doctor.ps1 scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 scripts/test-fleet-doctor.ps1 .claude-plugin/plugin.json
git commit -m "feat(models): seed taxonomy/floors/keep_list + doctor class column + bootstrap deploy + rc.7"
```

---

### Task 7: Final gate, adversarial review, merge, deploy, closeout

(Controller-level task — Kevin's standing style: ONE comprehensive adversarial review here, none per-task.)

- [ ] **Step 1: Full suite gate.** Run every suite touched plus the broad set:

```powershell
foreach ($t in @('test-fleet-lib','test-fleet-dispatch','test-fleet-doctor','test-routing-lib','test-routing-dispatch','test-routing-learn','test-routing-calibrate','test-routing-cascade','test-fleet-backlog','test-fleet-backlog-concurrent','test-fleet-models','test-bootstrap')) {
    Write-Host "== $t =="; & pwsh -NoProfile -File "scripts/$t.ps1"; if ($LASTEXITCODE -ne 0) { throw "$t FAILED" }
}
```

Expected: all green, exit 0.

- [ ] **Step 2: Adversarial review.** Dispatch an opus review subagent over the full branch diff (`git diff master...HEAD`) with the spec; fix anything accepted as real; re-run the gate.
- [ ] **Step 3: Gated merge.** Push branch, open PR titled `feat: models-as-tools registry — claims, judge claim, inventory, scorecard import`, merge to master, delete branch.
- [ ] **Step 4: Live deploy.** Run `scripts/bootstrap.ps1`; verify `fleet-models.ps1` lands in `~/.claude/scripts/`. Hand-edit live `~/.baton/fleet.yaml` (it is NOT overwritten by bootstrap): add `capability_floors` + `keep_list` blocks, claims/context/usage_class on lm-studio (`[code-gen, code-transform, summarize-short, synthesize]`, 32768, broad), lm-studio-small (`[judge, commit-msg, extract-json, summarize-short]`, 16384, tight), ollama-box2 (usage_class tight); REPLACE the "keep lm-studio-small ABOVE ollama-box2" file-order comment with a note that the judge claim now does the work.
- [ ] **Step 5: Live smoke.** (a) `pwsh -File ~/.claude/scripts/fleet-models.ps1` against the real LM Studio — expect a table of real models + sane recommendations; (b) `. ~/.claude/scripts/routing-lib.ps1; Get-JudgeModel` → expect `lm-studio-small`; (c) craft a tiny hand-made scorecard JSON and `--import` it into a TEMP ratings path (never the real store) to prove the surface end-to-end.
- [ ] **Step 6: Closeout.** Decision record (file-based intake) for the claims/judge/import design; docs/next-session.md entry; memory updates; push Baton + KB; prompt to /compact.
