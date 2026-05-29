# Plan 5: Research Ensemble Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fan a research prompt out to a roster of fleet members concurrently (process-isolated), collect each response as a file, and have Claude synthesize them. Ships `Invoke-FleetEnsemble` + `/ensemble` (job-optional) + `/research` (job-bound).

**Architecture:** A new `Invoke-FleetEnsemble` (in `scripts/fleet-ensemble.ps1`) spawns one `Start-Job` (separate PowerShell process) per provider, each dot-sourcing `fleet-lib.ps1` and running `Invoke-Fleet -NoJournal`, writing its response to `<OutputDir>/<provider>.md`. The parent waits (with timeout), then writes all `fleet | …` journal lines serially (avoiding concurrent-append corruption). Claude reads the collected files and synthesizes. A new `-NoJournal` switch on `Invoke-Fleet` lets workers dispatch-without-journaling so the parent owns all journal writes.

**Tech Stack:** PowerShell 7+ (pwsh), `Start-Job` process isolation. No Python changes (dashboard ensemble view is Plan 7). No new dependencies.

---

## Spec reference

`docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md`. Read it for rationale.

## Key contracts (from spec)

- **`Invoke-Fleet -NoJournal`**: dispatch + return result WITHOUT writing a journal line. Default (no switch) unchanged.
- **`Invoke-FleetEnsemble -Providers string[] -Prompt -OutputDir [-TimeoutS 300] [-FleetPath] [-JournalPath]`** → manifest `[pscustomobject]@{ provider; status; file; duration_s }[]`. `status` ∈ `ok` (exit 0) | `error` (non-zero/spawn fail) | `timeout`.
- **`Get-FleetResearchDefault -Path`** → `string[]` of provider names from the top-level `research_default:` key (empty array if absent).
- **Worker isolation**: each provider runs in its own `Start-Job` process (no env-var collision).
- **Journal**: parent writes N `fleet | <provider> | <Ns> | exit:N | "<prompt>"` lines SERIALLY after collecting; workers use `-NoJournal`. Timeout → exit `-2`, error → exit `-1`, ok → exit `0`.
- **Output dir**: `<job>/phases/research/ensemble-<timestamp>/` if a job is active, else `~/.claude/ensembles/<timestamp>/`. Per-provider `<name>.md` + a Claude-written `synthesis.md`.
- **Roster precedence**: explicit `--providers` > `--tier` filter (over enabled providers) > `research_default`.
- **Inherited limitation**: prompt double-quote escaping (Plan 4) is NOT re-hardened here.

## File structure

| Path | Responsibility |
|---|---|
| `scripts/fleet-lib.ps1` | MODIFY: add `-NoJournal` switch to `Invoke-Fleet`; add `Get-FleetResearchDefault` |
| `references/fleet.yaml` | MODIFY: add top-level `research_default:` key |
| `scripts/fixtures/fleet-sample.yaml` | MODIFY: add `research_default`, `stub-fail`, `stub-slow` |
| `scripts/test-fleet-lib.ps1` | MODIFY: tests for `-NoJournal` + `Get-FleetResearchDefault` |
| `scripts/fleet-ensemble.ps1` | NEW: `Invoke-FleetEnsemble` |
| `scripts/test-fleet-ensemble.ps1` | NEW: ensemble tests (stub providers) |
| `commands/ensemble.md` | NEW: `/ensemble` primitive command |
| `commands/research.md` | NEW: `/research` job-bound wrapper |
| `scripts/bootstrap.ps1` | MODIFY: deploy fleet-ensemble.ps1 + ensemble.md + research.md |
| `README.md` | MODIFY: Plan 5 section |

## Task ordering

Sequential. Foundation amendments first (Tasks 1-2), core primitive (Task 3), commands (4-5), bootstrap (6), README+smoke (7).

---

## Task 1: `-NoJournal` switch on `Invoke-Fleet`

**Files:**
- Modify: `scripts/fleet-lib.ps1`
- Modify: `scripts/test-fleet-lib.ps1`

- [ ] **Step 1: Add a failing test** — append to `scripts/test-fleet-lib.ps1` immediately BEFORE the final `if ($failures -gt 0)...` / `All tests passed.` block:

```powershell
# --- Invoke-Fleet -NoJournal ---
$njJournal = Join-Path $env:TEMP "fleet-nojournal-$(Get-Random).md"
$njState   = Join-Path $env:TEMP "fleet-nojournal-state-$(Get-Random).json"
$env:CAO_STATE_PATH = $njState   # no such file → no tags either way
try {
    $njResult = Invoke-Fleet -Name 'stub-cli' -Prompt 'x' -Path $fixture -JournalPath $njJournal -NoJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "NoJournal returns a result" (($njResult.stdout | Out-String).Trim() -eq 'hello-x')
Assert "NoJournal writes NO journal file content" (-not (Test-Path $njJournal) -or (@(Get-Content $njJournal -ErrorAction SilentlyContinue | Where-Object { $_ -match '\| fleet \|' }).Count -eq 0))
Remove-Item $njJournal -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-fleet-lib.ps1
```

Expected: FAIL — `Invoke-Fleet` has no `-NoJournal` parameter, so PowerShell throws "A parameter cannot be found that matches parameter name 'NoJournal'."

- [ ] **Step 3: Add the switch.** In `scripts/fleet-lib.ps1`, modify the `Invoke-Fleet` param block from:

```powershell
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model,
        [string]$Path = $script:DefaultFleetPath,
        [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md')
    )
```

to (add the switch):

```powershell
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model,
        [string]$Path = $script:DefaultFleetPath,
        [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
        [switch]$NoJournal
    )
```

And change the journaling call at the end of `Invoke-Fleet` from:

```powershell
    Write-FleetJournalLine -Provider $Name -DurationS $result.duration_s `
        -ExitCode $result.exit_code -Prompt $Prompt -JournalPath $JournalPath
    return $result
```

to:

```powershell
    if (-not $NoJournal) {
        Write-FleetJournalLine -Provider $Name -DurationS $result.duration_s `
            -ExitCode $result.exit_code -Prompt $Prompt -JournalPath $JournalPath
    }
    return $result
```

- [ ] **Step 4: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-fleet-lib.ps1
```

Expected: `All tests passed.` (including the existing Plan 4 fleet-lib tests — `/fleet test` default journaling must still work).

- [ ] **Step 5: Commit**

```powershell
git add scripts/fleet-lib.ps1 scripts/test-fleet-lib.ps1
git commit -m "feat(plan5): Invoke-Fleet -NoJournal switch (parent will serialize journal writes)"
```

---

## Task 2: `Get-FleetResearchDefault` + `research_default` key

**Files:**
- Modify: `scripts/fleet-lib.ps1`
- Modify: `references/fleet.yaml`
- Modify: `scripts/fixtures/fleet-sample.yaml`
- Modify: `scripts/test-fleet-lib.ps1`

- [ ] **Step 1: Add `research_default` to the fixture.** At the TOP of `scripts/fixtures/fleet-sample.yaml` (before `providers:`), add:

```yaml
research_default: [stub-cli, stub-with-model]
```

- [ ] **Step 2: Add a failing test** — append to `scripts/test-fleet-lib.ps1` before the final failure-check block:

```powershell
# --- Get-FleetResearchDefault ---
$rd = Get-FleetResearchDefault -Path $fixture
Assert "research_default returns 2 names" ($rd.Count -eq 2)
Assert "research_default first is stub-cli" ($rd[0] -eq 'stub-cli')
Assert "research_default second is stub-with-model" ($rd[1] -eq 'stub-with-model')

# absent key → empty array
$noRdFixture = Join-Path $env:TEMP "fleet-nord-$(Get-Random).yaml"
Set-Content -Path $noRdFixture -Value "providers:`n  - name: x`n    kind: cli`n    enabled: true`n    cost_tier: free`n    command_template: 'echo {{prompt}}'" -Encoding utf8NoBOM
$rdEmpty = Get-FleetResearchDefault -Path $noRdFixture
Assert "absent research_default → empty array" ($rdEmpty.Count -eq 0)
Remove-Item $noRdFixture -ErrorAction SilentlyContinue
```

- [ ] **Step 3: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-fleet-lib.ps1
```

Expected: `The term 'Get-FleetResearchDefault' is not recognized`.

- [ ] **Step 4: Add `Get-FleetResearchDefault` to `scripts/fleet-lib.ps1`** (append after `Get-FleetProvider`):

```powershell
function Get-FleetResearchDefault {
    <# Read the top-level `research_default: [a, b, c]` key from fleet.yaml.
       Returns a string[] of provider names (empty array if the key is absent). #>
    param([string]$Path = $script:DefaultFleetPath)
    if (-not (Test-Path $Path)) { return @() }
    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^\s*research_default:\s*\[(.*)\]\s*$') {
            $inner = $matches[1].Trim()
            if (-not $inner) { return @() }
            return @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
        }
    }
    return @()
}
```

- [ ] **Step 5: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-fleet-lib.ps1
```

Expected: `All tests passed.`.

- [ ] **Step 6: Add `research_default` to the real seed.** In `references/fleet.yaml`, add this line ABOVE the `providers:` line (after the header comment block):

```yaml
# Default roster for /research and /ensemble when no --providers/--tier given.
research_default: [claude-cli, codex, ollama-local]

providers:
```

- [ ] **Step 7: Verify the real seed parses**

```powershell
pwsh -NoProfile -Command ". ./scripts/fleet-lib.ps1; (Get-FleetResearchDefault -Path ./references/fleet.yaml) -join ','"
```

Expected output: `claude-cli,codex,ollama-local`.

- [ ] **Step 8: Commit**

```powershell
git add scripts/fleet-lib.ps1 scripts/test-fleet-lib.ps1 scripts/fixtures/fleet-sample.yaml references/fleet.yaml
git commit -m "feat(plan5): Get-FleetResearchDefault + research_default key in fleet.yaml"
```

---

## Task 3: `Invoke-FleetEnsemble` core + tests

**Files:**
- Modify: `scripts/fixtures/fleet-sample.yaml` (add `stub-fail`, `stub-slow`)
- Create: `scripts/fleet-ensemble.ps1`
- Create: `scripts/test-fleet-ensemble.ps1`

- [ ] **Step 1: Add test-stub providers to `scripts/fixtures/fleet-sample.yaml`.** Append these two entries under `providers:` (after the existing `stub-http` entry):

```yaml
  - name: stub-fail
    kind: cli
    enabled: true
    cost_tier: free
    command_template: 'pwsh -NoProfile -Command "exit 3"'

  - name: stub-slow
    kind: cli
    enabled: true
    cost_tier: free
    command_template: 'pwsh -NoProfile -Command "Start-Sleep -Seconds 10; Write-Output slow-{{prompt}}"'
```

- [ ] **Step 2: Write the failing test — `scripts/test-fleet-ensemble.ps1`**

```powershell
#!/usr/bin/env pwsh
# Tests for scripts/fleet-ensemble.ps1 (Invoke-FleetEnsemble) using stub providers.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-ensemble.ps1')

$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$noState = Join-Path $env:TEMP "ens-nostate-$(Get-Random).json"
$env:CAO_STATE_PATH = $noState   # no active job → untagged journal lines

# --- Test 1: basic concurrent success (2 providers) ---
$out1 = Join-Path $env:TEMP "ens-out1-$(Get-Random)"
$jrn1 = Join-Path $env:TEMP "ens-jrn1-$(Get-Random).md"
$m1 = Invoke-FleetEnsemble -Providers @('stub-cli','stub-with-model') -Prompt 'Q1' `
        -OutputDir $out1 -FleetPath $fixture -JournalPath $jrn1 -TimeoutS 60
Assert "T1 manifest has 2 entries" ($m1.Count -eq 2)
Assert "T1 stub-cli.md written" (Test-Path (Join-Path $out1 'stub-cli.md'))
Assert "T1 stub-cli content" ((Get-Content (Join-Path $out1 'stub-cli.md') -Raw).Trim() -eq 'hello-Q1')
Assert "T1 stub-with-model content" ((Get-Content (Join-Path $out1 'stub-with-model.md') -Raw).Trim() -eq 'default-model:Q1')
Assert "T1 both status ok" (@($m1 | Where-Object { $_.status -eq 'ok' }).Count -eq 2)
# Journal serialization: exactly 2 fleet lines, each well-formed
$fleetLines = @(Get-Content $jrn1 | Where-Object { $_ -match '\| fleet \|' })
Assert "T1 exactly 2 journal lines" ($fleetLines.Count -eq 2)
$shapeRe = '^\d{4}-\d{2}-\d{2}T\S+ \| fleet \| \S+ \| \d+s \| exit:-?\d+ \| ".*"'
Assert "T1 journal lines well-formed" (@($fleetLines | Where-Object { $_ -match $shapeRe }).Count -eq 2)
Remove-Item $out1 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn1 -ErrorAction SilentlyContinue

# --- Test 2: partial failure (stub-fail) doesn't sink the ensemble ---
$out2 = Join-Path $env:TEMP "ens-out2-$(Get-Random)"
$jrn2 = Join-Path $env:TEMP "ens-jrn2-$(Get-Random).md"
$m2 = Invoke-FleetEnsemble -Providers @('stub-cli','stub-fail') -Prompt 'Q2' `
        -OutputDir $out2 -FleetPath $fixture -JournalPath $jrn2 -TimeoutS 60
Assert "T2 manifest has 2 entries" ($m2.Count -eq 2)
Assert "T2 stub-cli ok" ((($m2 | Where-Object { $_.provider -eq 'stub-cli' }).status) -eq 'ok')
Assert "T2 stub-fail error" ((($m2 | Where-Object { $_.provider -eq 'stub-fail' }).status) -eq 'error')
Assert "T2 stub-fail file has error marker" ((Get-Content (Join-Path $out2 'stub-fail.md') -Raw) -match '\[ENSEMBLE ERROR\]')
Remove-Item $out2 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn2 -ErrorAction SilentlyContinue

# --- Test 3: timeout (stub-slow sleeps 10s, timeout 2s) ---
$out3 = Join-Path $env:TEMP "ens-out3-$(Get-Random)"
$jrn3 = Join-Path $env:TEMP "ens-jrn3-$(Get-Random).md"
$t0 = Get-Date
$m3 = Invoke-FleetEnsemble -Providers @('stub-slow') -Prompt 'Q3' `
        -OutputDir $out3 -FleetPath $fixture -JournalPath $jrn3 -TimeoutS 2
$elapsed = ((Get-Date) - $t0).TotalSeconds
Assert "T3 status timeout" ((($m3 | Where-Object { $_.provider -eq 'stub-slow' }).status) -eq 'timeout')
Assert "T3 file has timeout marker" ((Get-Content (Join-Path $out3 'stub-slow.md') -Raw) -match '\[ENSEMBLE TIMEOUT\]')
Assert "T3 returned well under the 10s sleep" ($elapsed -lt 8)
Remove-Item $out3 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $jrn3 -ErrorAction SilentlyContinue

Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
```

- [ ] **Step 3: Run to verify failure**

```powershell
pwsh -NoProfile -File scripts\test-fleet-ensemble.ps1
```

Expected: `Cannot find path …\fleet-ensemble.ps1` (or `Invoke-FleetEnsemble not recognized`).

- [ ] **Step 4: Create `scripts/fleet-ensemble.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Concurrent fan-out of one prompt to a roster of fleet members.

.DESCRIPTION
  One Start-Job (separate PowerShell process) per provider — process isolation
  prevents env-var collision and contains crashes/hangs. Each job dot-sources
  fleet-lib.ps1 and runs Invoke-Fleet -NoJournal, writing its response to
  <OutputDir>/<provider>.md. The parent waits (with timeout), then writes all
  journal lines SERIALLY (avoiding concurrent-append corruption). Returns a
  manifest. Synthesis is done by the caller (Claude), not here.
#>

. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

function Invoke-FleetEnsemble {
    param(
        [Parameter(Mandatory)][string[]]$Providers,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$OutputDir,
        [int]$TimeoutS = 300,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md')
    )
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $libPath = Join-Path $PSScriptRoot 'fleet-lib.ps1'

    # Spawn one process-isolated job per provider.
    $jobMap = @()
    foreach ($p in $Providers) {
        $job = Start-Job -ArgumentList $libPath, $p, $Prompt, $OutputDir, $FleetPath -ScriptBlock {
            param($libPath, $provider, $prompt, $outDir, $fleetPath)
            . $libPath
            $outFile = Join-Path $outDir "$provider.md"
            try {
                $r = Invoke-Fleet -Name $provider -Prompt $prompt -Path $fleetPath -NoJournal
                if ($r.exit_code -eq 0) {
                    Set-Content -Path $outFile -Value ($r.stdout | Out-String).Trim() -Encoding utf8NoBOM
                } else {
                    Set-Content -Path $outFile -Value "[ENSEMBLE ERROR] exit:$($r.exit_code) $($r.stderr)" -Encoding utf8NoBOM
                }
                [pscustomobject]@{ exit_code = $r.exit_code; duration_s = $r.duration_s }
            } catch {
                Set-Content -Path $outFile -Value "[ENSEMBLE ERROR] $($_.Exception.Message)" -Encoding utf8NoBOM
                [pscustomobject]@{ exit_code = -1; duration_s = 0 }
            }
        }
        $jobMap += [pscustomobject]@{ provider = $p; job = $job }
    }

    # Wait for all jobs, bounded by TimeoutS.
    $null = Wait-Job -Job ($jobMap.job) -Timeout $TimeoutS

    $manifest = @()
    foreach ($entry in $jobMap) {
        $job = $entry.job
        $prov = $entry.provider
        $outFile = Join-Path $OutputDir "$prov.md"
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job
            Set-Content -Path $outFile -Value "[ENSEMBLE TIMEOUT] exceeded ${TimeoutS}s" -Encoding utf8NoBOM
            $manifest += [pscustomobject]@{ provider = $prov; status = 'timeout'; file = $outFile; duration_s = $TimeoutS }
        } else {
            $ret = Receive-Job -Job $job
            $exit = if ($ret -and $null -ne $ret.exit_code) { [int]$ret.exit_code } else { -1 }
            $dur  = if ($ret -and $null -ne $ret.duration_s) { [int]$ret.duration_s } else { 0 }
            $status = if ($exit -eq 0) { 'ok' } else { 'error' }
            $manifest += [pscustomobject]@{ provider = $prov; status = $status; file = $outFile; duration_s = $dur }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    # Parent writes journal lines SERIALLY (no concurrent appends).
    foreach ($m in $manifest) {
        $jexit = switch ($m.status) { 'ok' { 0 } 'timeout' { -2 } default { -1 } }
        Write-FleetJournalLine -Provider $m.provider -DurationS $m.duration_s `
            -ExitCode $jexit -Prompt $Prompt -JournalPath $JournalPath
    }

    return $manifest
}
```

- [ ] **Step 5: Run to verify pass**

```powershell
pwsh -NoProfile -File scripts\test-fleet-ensemble.ps1
```

Expected: `All tests passed.` (Test 3 finishes in ~2-4s, not 10s — proving the timeout kills the straggler.)

- [ ] **Step 6: Commit**

```powershell
git add scripts/fleet-ensemble.ps1 scripts/test-fleet-ensemble.ps1 scripts/fixtures/fleet-sample.yaml
git commit -m "feat(plan5): Invoke-FleetEnsemble — Start-Job fan-out + serial journaling + tests"
```

---

## Task 4: `/ensemble` slash command

**Files:**
- Create: `commands/ensemble.md`

- [ ] **Step 1: Create `commands/ensemble.md`** (use LITERAL triple-backticks in the file; the escaped form below is for readability):

```markdown
---
description: Fan a prompt out to multiple fleet members concurrently, then synthesize their responses. Job-optional. Roster from --providers, --tier, or fleet.yaml research_default.
argument-hint: "<prompt>" [--providers a,b,c] [--tier free,local]
---

# /ensemble

Run a concurrent multi-model ensemble and synthesize the results.

## Steps

1. **Parse `$ARGUMENTS`:** the quoted string is the prompt; optional
   `--providers a,b,c` (comma list) and `--tier free,local` (comma list of
   paid/free/local).

2. **Resolve the roster** (first match wins):
   - if `--providers` given → that list (drop unknown/disabled with a warning)
   - else if `--tier` given → all enabled providers whose `cost_tier` is in the list
   - else → `Get-FleetResearchDefault`
   If the resolved roster is empty, stop with:
   *"No providers resolved. Check --providers/--tier or research_default in fleet.yaml."*

   \`\`\`powershell
   . "$HOME/.claude/scripts/fleet-lib.ps1"
   $explicit = @( <comma-split of --providers, or empty> )
   $tiers    = @( <comma-split of --tier, or empty> )
   if ($explicit.Count) {
       $all = Read-Fleet
       $roster = @($explicit | Where-Object { $n = $_; ($all | Where-Object { $_.name -eq $n -and $_.enabled -eq $true }) })
   } elseif ($tiers.Count) {
       $roster = @((Read-Fleet | Where-Object { $_.enabled -eq $true -and $tiers -contains $_.cost_tier }).name)
   } else {
       $roster = @(Get-FleetResearchDefault)
   }
   if (-not $roster.Count) { Write-Host "No providers resolved." -ForegroundColor Red; return }
   $roster -join ','
   \`\`\`

3. **Pick the output dir.** If a job is active (`~/.claude/current-job.json` has
   a job_id), use `<job>/phases/research/ensemble-<timestamp>/`; else
   `~/.claude/ensembles/<timestamp>/`. Timestamp format `yyyy-MM-ddTHH-mm-ss`.

   \`\`\`powershell
   . "$HOME/.claude/scripts/job-lib.ps1"   # Read-CurrentJob lives in job-lib
   $ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
   $state = Read-CurrentJob
   if ($state.job_id) {
       $outDir = Join-Path $HOME ".claude/jobs/$($state.job_id)/phases/research/ensemble-$ts"
   } else {
       $outDir = Join-Path $HOME ".claude/ensembles/$ts"
   }
   $outDir
   \`\`\`

4. **Run the ensemble:**

   \`\`\`powershell
   . "$HOME/.claude/scripts/fleet-ensemble.ps1"
   $manifest = Invoke-FleetEnsemble -Providers @(<roster>) -Prompt '<prompt>' -OutputDir '<outDir>'
   $manifest | Format-Table -AutoSize
   \`\`\`

5. **Synthesize.** Read each `<outDir>/<provider>.md`. Write a synthesis to
   `<outDir>/synthesis.md` covering: where the models AGREE, where they DIVERGE
   (and why it matters), any UNIQUE insight only one surfaced, and a RECOMMENDED
   direction. Do not use a rigid template — structure it to fit the content.
   Skip any provider whose file starts with `[ENSEMBLE ERROR]` or
   `[ENSEMBLE TIMEOUT]`, but note the gap. If ALL failed, skip synthesis and
   suggest `/fleet doctor`.

6. **Present** the synthesis to the user and report which providers
   succeeded/failed (from the manifest).

## Arguments

$ARGUMENTS
```

- [ ] **Step 2: Commit**

```powershell
git add commands/ensemble.md
git commit -m "feat(plan5): /ensemble slash command (primitive, job-optional)"
```

---

## Task 5: `/research` slash command

**Files:**
- Create: `commands/research.md`

- [ ] **Step 1: Create `commands/research.md`** (literal triple-backticks in the file):

```markdown
---
description: Research-phase ensemble. Requires an active job; fans out to the roster, writes to the job's phases/research/, and synthesizes. Wrapper over the ensemble primitive.
argument-hint: "<question>" [--providers a,b,c] [--tier free,local]
---

# /research

Run a research ensemble within the active job's research phase.

## Steps

1. **Require an active job.** Read `~/.claude/current-job.json`. If no
   `job_id`, stop with: *"No active job. Use /ensemble for an ad-hoc run, or
   /job-start to begin a job."*

2. **Phase check.** If the job's `current_phase` (from its manifest) is not
   `research`, warn: *"Current phase is <x>; running research anyway."* Proceed.

3. **Resolve the roster** exactly as `/ensemble` does (explicit `--providers` >
   `--tier` > `Get-FleetResearchDefault`). Empty → stop with the same message.

4. **Output dir** is fixed to the job's research phase:

   \`\`\`powershell
   . "$HOME/.claude/scripts/job-lib.ps1"   # Read-CurrentJob + Read-Manifest live in job-lib
   $state = Read-CurrentJob
   $ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
   $outDir = Join-Path $HOME ".claude/jobs/$($state.job_id)/phases/research/ensemble-$ts"
   $outDir
   \`\`\`

5. **Run the ensemble + synthesize** exactly as `/ensemble` steps 4-6 (write
   `synthesis.md`, present it, report successes/failures).

6. **Prompt for a lesson** (non-blocking): *"Capture a lesson from this
   research? e.g. `/job-lesson knowledge \"<takeaway>\"`."*

## Arguments

$ARGUMENTS
```

- [ ] **Step 2: Commit**

```powershell
git add commands/research.md
git commit -m "feat(plan5): /research slash command (job-bound research-phase wrapper)"
```

---

## Task 6: Bootstrap extensions

**Files:**
- Modify: `scripts/bootstrap.ps1`

- [ ] **Step 1: Read `scripts/bootstrap.ps1`** to find the Plan 4 scripts foreach (the `@('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1')` list) and the slash-commands foreach.

- [ ] **Step 2: Add `fleet-ensemble.ps1` to the scripts foreach.** Change:

```powershell
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1')) {
```

to:

```powershell
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1')) {
```

- [ ] **Step 3: Add the two commands to the slash-commands foreach.** Change the command list to include `'ensemble.md'` and `'research.md'`:

```powershell
foreach ($cmd in @(
    'log-routing.md','consolidate-routing.md',
    'job-start.md','job-status.md','job-list.md','job-phase.md',
    'job-resume.md','job-lesson.md','consolidate-lessons.md',
    'fleet.md','ensemble.md','research.md'
)) {
```

- [ ] **Step 4: Dry-run**

```powershell
pwsh -NoProfile -File scripts\bootstrap.ps1 -DryRun
```

Expected: would-deploy lines for `fleet-ensemble.ps1`, `ensemble.md`, `research.md`. No errors.

- [ ] **Step 5: Real run**

```powershell
pwsh -NoProfile -File scripts\bootstrap.ps1
```

Expected: `fleet-ensemble.ps1` deployed to `~/.claude/scripts/`, `ensemble.md` + `research.md` to `~/.claude/commands/`. The `fleet.yaml` seed will prompt to overwrite (it now has `research_default`) — accept to get the new key, or keep if you've customized (then add `research_default` manually).

- [ ] **Step 6: Verify**

```powershell
Get-ChildItem $HOME\.claude\scripts\fleet-ensemble.ps1, $HOME\.claude\commands\ensemble.md, $HOME\.claude\commands\research.md | Select-Object FullName
```

- [ ] **Step 7: Commit**

```powershell
git add scripts/bootstrap.ps1
git commit -m "feat(plan5): bootstrap deploys fleet-ensemble.ps1 + /ensemble + /research"
```

---

## Task 7: README + end-to-end smoke

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the `## Coming in Plan 5` section in `README.md`** with:

```markdown
## What you get (Plan 5)

Concurrent multi-model **research ensembles**. Fan one prompt out to several
fleet members at once, then Claude synthesizes their responses.

- `/ensemble "<prompt>" [--providers a,b,c | --tier free,local]` — job-optional.
  Runs the roster concurrently (process-isolated `Start-Job`s), collects each
  response as a file, Claude writes a synthesis. Standalone runs land in
  `~/.claude/ensembles/<timestamp>/`.
- `/research "<question>"` — job-bound wrapper: writes to the active job's
  `phases/research/ensemble-<timestamp>/`, warns if you're not in the research
  phase, and nudges you to capture a lesson afterward.
- Roster precedence: `--providers` > `--tier` > `research_default` (a new
  top-level key in `fleet.yaml`).
- A failing or slow provider never sinks the ensemble — partial synthesis still
  happens; stragglers are killed at the timeout (default 300s).
- Per-provider `fleet | …` journal lines are written serially by the parent
  (tagged with the active job's `job:`/`phase:`), so concurrent runs never
  corrupt the journal.

See [`docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md`](docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md).

## Coming in Plan 5b / 5c

6 Thinking Hats (each model wears a hat) and LLM Council (models critique each
other's outputs) — thin presets built on the same ensemble primitive.
```

- [ ] **Step 2: Run the full test suite**

```powershell
pwsh -NoProfile -File scripts\test-fleet-lib.ps1
pwsh -NoProfile -File scripts\test-fleet-ensemble.ps1
pwsh -NoProfile -File scripts\test-fleet-dispatch.ps1
pwsh -NoProfile -File scripts\test-fleet-doctor.ps1
pwsh -NoProfile -File scripts\test-job-lib.ps1
pwsh -NoProfile -File scripts\test-jobs.ps1
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-otel-parser.ps1
pwsh -NoProfile -File scripts\test-consolidate-lessons.ps1
python -m pytest dashboard/tests/ -q
```

Expected: every PS script ends with `All tests passed.`; pytest all passed. No regressions.

- [ ] **Step 3: End-to-end smoke (manual, eyeball)** — from a Claude Code session in the repo, after bootstrap. Uses fast local/stub providers to avoid paid spend:

```
/ensemble "Name one tradeoff of feature flags" --providers ollama-local
   → response file + synthesis printed; ~/.claude/ensembles/<ts>/ created
/job-start "plan 5 smoke"
/research "What are common feature-flag rollout strategies?" --providers ollama-local
   → writes to ~/.claude/jobs/<id>/phases/research/ensemble-<ts>/
   → journal line: fleet | ollama-local | … | job:<id> | phase:research
/job-phase done
```

- [ ] **Step 4: Commit + tag**

```powershell
git add README.md
git commit -m "docs: Plan 5 README — research ensemble"
git tag plan5-complete -m "Plan 5: research ensemble (concurrent fan-out + synthesis)"
```

---

## End of plan
